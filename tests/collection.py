#!/usr/bin/env python3
"""Run a collection of dinix services in a container and ask it questions.

This script is generic.  A service port writes no Python: it declares the
collection and its checks in Nix, and `dev.nix` passes them here as
`vms.settings`.  See PORTING.md.

What every collection gets, without asking:

    start     the image loads and the container runs
    socket    dinit answers on its control socket
    started   every service named reaches "started"
    checks    each declared command runs inside the container and its
              output contains what the check expects
    quiet     no service failed while all that happened
    sigterm   SIGTERM stops the container well inside a grace period

The container gets the shape Kubernetes gives one: a read-only root
filesystem, tmpfs where something must be written, and the user database
mounted a file at a time.  A check runs through `podman exec` with an absolute
store path, so a collection image needs no shell.
"""

from uml_runner import MachineError, Machines, run_test
from uml_runner.cluster import until

NAME = "dinix-collection"

# The files a container gets from dinix, mounted one at a time.  A volume over
# /etc would hide the /etc/hosts and /etc/resolv.conf the runtime puts there.
ETC = ["passwd", "group", "shadow", "nsswitch.conf"]

# podman kills a container that has not stopped within its own default of 10s,
# and Kubernetes waits 30.  Either is a long way from what dinit needs.
STOP_BUDGET_MS = 5000


def run_args(settings: dict) -> str:
    mounts = [
        f"--volume {settings['configDir']}/etc/{etc}:/etc/{etc}:ro" for etc in ETC
    ]
    tmpfs = [f"--tmpfs {path}" for path in settings["tmpfs"]]
    return " ".join(
        [
            f"--name {NAME}",
            # The guest's own network. netavark and nftables are not what a
            # service port is about.
            "--network host",
            "--read-only",
            *tmpfs,
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
    dinitctl = settings["dinitctl"]

    print(f"[test] collection {settings['collection']}", flush=True)

    await node.succeed(settings["copyToPodman"], timeout=900)
    await node.succeed(
        f"podman run --detach {run_args(settings)} {settings['imageRef']}",
        timeout=300,
    )

    async def answering() -> tuple[bool, str]:
        code, out = await node.execute(
            f"podman exec {NAME} {dinitctl} list 2>&1", timeout=60
        )
        return code == 0, out.strip() or "(no control socket yet)"

    try:
        await until("dinit to answer on its control socket", answering, 180, node)
    except Exception:
        logs = await node.succeed(f"podman logs {NAME}")
        raise MachineError(
            f"[{node.name}] dinit never answered.\n--- container log ---\n{logs}"
        ) from None

    # Every service the collection declared, by name. is-started rather than
    # parsing `dinitctl list`: it answers with an exit code, which is what a
    # poll wants.
    for service in settings["services"]:

        async def started(service: str = service) -> tuple[bool, str]:
            code, _ = await node.execute(
                f"podman exec {NAME} {dinitctl} is-started {service}", timeout=60
            )
            status = await node.succeed(
                f"podman exec {NAME} {dinitctl} status {service} 2>&1", timeout=60
            )
            return code == 0, last_line(status) or "(no status)"

        try:
            await until(f"{service} to start", started, 180, node)
        except Exception:
            logs = await node.succeed(f"podman logs {NAME}")
            raise MachineError(
                f"[{node.name}] {service} never started.\n--- container log ---\n{logs}"
            ) from None
    print(f"[test] every service started: {', '.join(settings['services'])}", flush=True)

    logs = await node.succeed(f"podman logs {NAME}")
    print(f"[test] the container's own log:\n{logs}", flush=True)

    for check in settings["checks"]:
        code, out = await node.execute(
            f"podman exec {NAME} {check['command']} 2>&1", timeout=120
        )
        if code != 0 or check["expect"] not in out:
            raise MachineError(
                f"[{node.name}] check {check['name']!r} failed (exit {code}).\n"
                f"  ran:      {check['command']}\n"
                f"  expected: {check['expect']!r}\n"
                f"  got:      {out.strip()!r}\n"
                f"--- container log ---\n{logs}"
            )
        print(f"[test] {check['name']}", flush=True)

    # dinit reports a service that died at console-level warn, which dinix
    # leaves on for exactly this. Nothing above would notice a service that
    # started, answered and then fell over.
    for died in ("terminated with exit code", "failed to start"):
        if died in logs:
            raise MachineError(
                f"[{node.name}] a service failed while the checks were passing:\n{logs}"
            )

    elapsed = await node.succeed(
        "start=$(date +%s%3N)"
        f" && podman stop --time 30 {NAME} > /dev/null"
        " && end=$(date +%s%3N) && echo $((end - start))",
        timeout=120,
    )
    milliseconds = int(last_line(elapsed))
    if milliseconds > STOP_BUDGET_MS:
        raise MachineError(
            f"[{node.name}] SIGTERM to the container took {milliseconds}ms, over "
            f"the {STOP_BUDGET_MS}ms this test allows. A pod deletion would wait "
            f"out its grace period."
        )
    print(f"[test] SIGTERM stopped the container in {milliseconds}ms", flush=True)

    await node.succeed(f"podman rm --force {NAME}")


run_test(test)
