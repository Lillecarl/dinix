#!/usr/bin/env python3
"""Run a collection of dinix services and ask it questions.

This script is generic.  A service port writes no Python: it declares the
collection and its checks in Nix, and `dev.nix` passes them here as
`vms.settings`.  See PORTING.md.

Four modes, one per reasonable environment (`vms.settings["mode"]`):

    root     the image runs as root under podman, tmpfs for /run and
             for the state directory
    user     the same image runs as nobody: a podman tmpfs arrives 1777,
             so no chown, no run-as, and the services run as the
             container user
    vm-root  no container at all; dinit runs as root on the guest, state
             under $DINIX_STATE_DIR, no dinix-init
    vm-user  no container and no privilege; dinit --user runs as an
             ordinary guest account, state just the same

What every mode gets, without asking:

    start     the system loads and dinit answers on its control socket
    started   every service named reaches "started"
    checks    each declared command runs and its output contains what the
              check expects
    quiet     no service failed while all that happened
    sigterm   SIGTERM stops dinit well inside a grace period

The containers run writable. The test proves services start and answer;
a deployment with a read-only root mounts the writable paths itself —
/run always, the declared ones per service — and nothing here second-guesses
it. What the container mounts is a tmpfs for /run, a tmpfs for the state
directory, and the user database a file at a time. A check runs through
`podman exec` with an absolute store path, so a collection image needs no
shell.
"""

from uml_runner import Machine, MachineError, Machines, run_test
from uml_runner.cluster import until

from types import SimpleNamespace

NAME = "dinix-collection"

# The account the vm-user mode runs dinit as: the same nobody every
# unprivileged mode runs as, so services keep one identity across modes
# and no output names a user. The driver never creates users, it only
# runs things as this one. Dropping privilege uses setpriv rather than
# runuser or su: those open a PAM session, and with no logind on the
# guest that hangs. setpriv is syscalls all the way down.
VM_USER = "nobody"

# The files a container gets from dinix, mounted one at a time.  A volume over
# /etc would hide the /etc/hosts and /etc/resolv.conf the runtime puts there.
ETC = ["passwd", "group", "shadow", "nsswitch.conf"]

# What this catches is dinit ignoring SIGTERM, which shows up as the full
# `--time 30` wait and then a kill. It is not a benchmark: the number includes
# podman's own work and whatever else shares the processor, and the matrix runs
# guests in parallel. 10s is podman's own kill deadline, so it is the threshold
# where behaviour actually changes rather than a figure picked to look tight.
#
# Measured on an idle machine: 219ms uncontained, 2.2s under podman. The same
# container measured 5.1s with three other guests running, which failed a 5s
# bound that was testing the machine's load rather than dinit.
STOP_BUDGET_MS = 10_000

# How long a check may take to start passing. Not a timeout on the command --
# each of those has its own -- but the window in which a service that has
# spawned is allowed to finish becoming useful.
CHECK_BUDGET_S = 60


def run_args(settings: dict, state_mount: str) -> str:
    mounts = [
        f"--volume {settings['configDir']}/etc/{etc}:/etc/{etc}:ro" for etc in ETC
    ] + [
        # /run holds dinit's control socket, and the state directory everything
        # the services keep. Both arrive as tmpfs: ephemeral like an emptyDir,
        # and 1777, which is what lets the nobody container write them too.
        "--tmpfs /run",
        state_mount,
    ]
    return " ".join(
        [
            f"--name {NAME}",
            # The guest's own network. netavark and nftables are not what a
            # service port is about.
            "--network host",
            # dinit substitutes this when it loads a service description, and
            # dinix-init expands it over init.spec, so one image puts its state
            # wherever the deployment says. Naming a path that is not the
            # /var/lib default is deliberate: it is what proves the
            # substitution happened rather than the default surviving.
            f"--env DINIX_STATE_DIR={settings['stateDir']}",
            *mounts,
            # Empty when the container runs as root, which is podman's default.
            settings["podmanUser"] and f"--user {settings['podmanUser']}",
        ]
    ).strip()


def last_line(output: str) -> str:
    lines = output.strip().splitlines()
    return lines[-1].strip() if lines else ""


async def test(vms: Machines) -> None:
    node = vms.node
    settings = vms.settings
    mode = settings["mode"]

    print(f"[test] collection {settings['collection']} in {mode} mode", flush=True)

    if mode in ("root", "user"):
        target = await start_container(node, settings)
    else:
        target = await start_vm(node, settings)

    try:
        await wait_for_socket(node, settings, target)
        await wait_for_services(node, settings, target)
        logs = await target.logs()
        print(f"[test] {target.log_title}:\n{logs}", flush=True)
        await run_checks(node, settings, target, logs)
        await quiet_check(node, settings, target, logs)
        await stop_cleanly(node, settings, target)
    finally:
        await target.cleanup()

    print(f"[test] {settings['collection']} passed in {mode} mode", flush=True)


async def start_container(node: Machine, settings: dict) -> SimpleNamespace:
    dinitctl = settings["dinitctl"]

    # One state mount, which dinix-init populates: a tmpfs either way. It
    # arrives 1777, so the nobody container makes its data directories on it
    # like root does; dinix-init stats before chowning and skips what already
    # belongs to the account, which is everything here. The guest is thrown
    # away with the test, so nothing cleans it.
    state_mount = f"--tmpfs {settings['stateDir']}"

    await node.succeed(settings["copyToPodman"], timeout=900)
    await node.succeed(
        f"podman run --detach {run_args(settings, state_mount)} {settings['imageRef']}",
        timeout=300,
    )

    async def logs() -> str:
        return await node.succeed(f"podman logs {NAME}")

    async def stop_ms() -> int:
        elapsed = await node.succeed(
            "start=$(date +%s%3N)"
            f" && podman stop --time 30 {NAME} > /dev/null"
            " && end=$(date +%s%3N) && echo $((end - start))",
            timeout=120,
        )
        return int(last_line(elapsed))

    async def cleanup() -> None:
        await node.succeed(f"podman rm --force {NAME}")

    return SimpleNamespace(
        run=lambda cmd: f"podman exec {NAME} {cmd}",
        ctl=f"podman exec {NAME} {dinitctl}",
        log_title="the container's own log",
        logs=logs,
        stop_ms=stop_ms,
        stop_what="the container",
        cleanup=cleanup,
    )

async def wait_for_socket(node: Machine, settings: dict, target: SimpleNamespace) -> None:
    async def answering() -> tuple[bool, str]:
        code, out = await node.execute(f"{target.ctl} list 2>&1", timeout=60)
        return code == 0, out.strip() or "(no control socket yet)"

    try:
        await until("dinit to answer on its control socket", answering, 180, node)
    except Exception:
        logs = await target.logs()
        raise MachineError(
            f"[{node.name}] dinit never answered.\n--- {target.log_title} ---\n{logs}"
        ) from None


async def wait_for_services(node: Machine, settings: dict, target: SimpleNamespace) -> None:
    # Every service the collection declared, by name. is-started rather than
    # parsing `dinitctl list`: it answers with an exit code, which is what a
    # poll wants.
    for service in settings["services"]:

        async def started(service: str = service) -> tuple[bool, str]:
            code, _ = await node.execute(
                f"{target.ctl} is-started {service}", timeout=60
            )
            status = await node.succeed(
                f"{target.ctl} status {service} 2>&1", timeout=60
            )
            return code == 0, last_line(status) or "(no status)"

        try:
            await until(f"{service} to start", started, 180, node)
        except Exception:
            logs = await target.logs()
            raise MachineError(
                f"[{node.name}] {service} never started.\n--- {target.log_title} ---\n{logs}"
            ) from None
    print(f"[test] every service started: {', '.join(settings['services'])}", flush=True)


async def service_states(
    node: Machine, settings: dict, target: SimpleNamespace
) -> str:
    """What dinit thinks of each service, for a failure message.

    dinit marks a process service started the moment it spawns, so a program
    that dies immediately still passes `is-started` and the first check is what
    notices.  The status says so where the log does not: dinit prints nothing
    of its own about a service that exits quietly, which left an empty log as
    the only evidence more than once.
    """
    lines = []
    for service in settings["services"]:
        _, status = await node.execute(
            f"{target.ctl} status {service} 2>&1", timeout=60
        )
        lines.append(f"{service}: {' '.join(status.split())}")
    return "\n".join(lines) + "\n"


async def run_checks(
    node: Machine, settings: dict, target: SimpleNamespace, logs: str
) -> None:
    for check in settings["checks"]:
        # Retried, not asked once. dinit marks a process service started the
        # moment it spawns, and the portable service interface has no readiness
        # probe at all -- see Lillecarl/dinix#15 -- so "started" says nothing
        # about whether the program has bound its port yet. Without this the
        # result depends on which won the race, which is how the same
        # collection passed as an ordinary user and failed as root.
        async def attempt(check: dict = check) -> tuple[bool, str]:
            code, out = await node.execute(
                f"{target.run(check['command'])} 2>&1", timeout=120
            )
            return code == 0 and check["expect"] in out, f"exit {code}: {out.strip()[:200]}"

        try:
            await until(check["name"], attempt, CHECK_BUDGET_S, node)
        except Exception:
            code, out = await node.execute(
                f"{target.run(check['command'])} 2>&1", timeout=120
            )
            raise MachineError(
                f"[{node.name}] check {check['name']!r} failed (exit {code}).\n"
                f"  ran:      {check['command']}\n"
                f"  expected: {check['expect']!r}\n"
                f"  got:      {out.strip()!r}\n"
                f"--- {target.log_title} ---\n{logs}"
                f"--- what dinit says about each service ---\n"
                f"{await service_states(node, settings, target)}"
            ) from None
        print(f"[test] {check['name']}", flush=True)


async def quiet_check(
    node: Machine, settings: dict, target: SimpleNamespace, logs: str
) -> None:
    # dinit reports a service that died at console-level warn, which dinix
    # leaves on for exactly this. Nothing above would notice a service that
    # started, answered and then fell over.
    for died in ("terminated with exit code", "failed to start"):
        if died in logs:
            raise MachineError(
                f"[{node.name}] a service failed while the checks were passing:\n{logs}"
            )


async def stop_cleanly(node: Machine, settings: dict, target: SimpleNamespace) -> None:
    milliseconds = await target.stop_ms()
    if milliseconds > STOP_BUDGET_MS:
        raise MachineError(
            f"[{node.name}] SIGTERM to {target.stop_what} took {milliseconds}ms, over "
            f"the {STOP_BUDGET_MS}ms this test allows. A pod deletion would wait "
            f"out its grace period."
        )
    print(f"[test] SIGTERM stopped {target.stop_what} in {milliseconds}ms", flush=True)


async def start_vm(node: Machine, settings: dict) -> SimpleNamespace:
    as_user = settings["mode"] == "vm-user"
    dinit = settings["dinit"]
    dinitctl = settings["dinitctl"]
    state = settings["stateDir"]
    log = f"{state}/dinix-{settings['collection']}-{settings['mode']}.log"
    pidfile = f"{state}/dinix-{settings['collection']}-{settings['mode']}.pid"
    sock = f"{state}/dinit.sock"

    # Who the guest runs commands as, and what privilege tools it has. This
    # is the provenance every mode below depends on: the agent is a root
    # systemd unit, but that is worth one line of evidence rather than an
    # assumption.
    prov = await node.succeed(
        "id -u; command -v setpriv runuser su; ls -ld /tmp", timeout=60
    )
    print(f"[test] guest shell:\n{prov}", flush=True)

    # The state directory belongs to the account dinit runs as, and with it
    # everything under it that the services keep. The driver runs as root
    # either way; in vm-root that is also the account, so nothing is handed
    # over. Everything a user touches below it creates itself: the guest's
    # filesystem refuses a file one user made to another, so the log, the
    # pid file and the socket are written by whoever runs dinit, never by
    # the driver.
    # Only the state directory itself, and only because dinit's own socket and
    # log go in it before any service runs. Everything under it is dinix-init's
    # to make, in this mode as in the containers: a driver that made the data
    # directories first would hide the failure this test exists to catch, a
    # service whose directory dinix never declared.
    await node.succeed(f"mkdir --parents {state}", timeout=60)
    if as_user:
        await node.succeed(f"chown {VM_USER} {state}", timeout=60)

    if as_user:
        # dinit --user takes no container flags, and the wrapper bakes in
        # no socket path, so both are said here. Numeric ids: this setpriv
        # parses --reuid by name but --regid by number only, so both are
        # resolved first.
        ids = await node.succeed(f"id -u {VM_USER}; id -g {VM_USER}", timeout=60)
        uid, gid = ids.split()
        become = f"setpriv --reuid {uid} --regid {gid} --clear-groups -- "
        start = (
            f"{become}/bin/sh -c 'echo $$ > {pidfile};"
            f" export DINIX_STATE_DIR={state};"
            f" exec {dinit} --user --socket-path {sock} > {log} 2>&1' & echo $!"
        )
        ctl = f"{become}env DINIT_SOCKET_PATH={sock} {dinitctl}"
        run = lambda cmd: f"{become}env DINIX_STATE_DIR={state} {cmd}"
    else:
        start = (
            f"/bin/sh -c 'echo $$ > {pidfile};"
            f" export DINIX_STATE_DIR={state};"
            f" exec {dinit} --socket-path {sock} > {log} 2>&1' & echo $!"
        )
        ctl = f"env DINIT_SOCKET_PATH={sock} {dinitctl}"
        run = lambda cmd: f"env DINIX_STATE_DIR={state} {cmd}"

    out = await node.succeed(start, timeout=60)
    # The launch output is the only place a failure to start speaks: a
    # missing privilege tool or a bad flag dies here, before any socket
    # exists to poll for.
    if out.strip():
        print(f"[test] launch said:\n{out}", flush=True)
    launched = await node.succeed(
        f"for i in $(seq 1 50); do [ -s {pidfile} ] && break; sleep 0.1; done"
        f" && cat {pidfile}",
        timeout=60,
    )
    pid = launched.strip()
    print(f"[test] dinit runs as pid {pid}", flush=True)

    async def logs() -> str:
        return await node.succeed(f"cat {log}")

    async def stop_ms() -> int:
        elapsed = await node.succeed(
            "start=$(date +%s%3N)"
            f" && kill {pid} && for i in $(seq 1 300); do kill -0 {pid} 2>/dev/null || break; sleep 0.1; done"
            " && end=$(date +%s%3N) && echo $((end - start))",
            timeout=120,
        )
        return int(last_line(elapsed))

    async def cleanup() -> None:
        return None

    return SimpleNamespace(
        run=run,
        ctl=ctl,
        log_title="dinit's own log",
        logs=logs,
        stop_ms=stop_ms,
        stop_what="dinit",
        cleanup=cleanup,
    )


run_test(test)
