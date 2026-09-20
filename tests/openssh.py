#!/usr/bin/env python3
"""Does a dinix container actually work?

Everything dinix claims about a container is argued from dinit's source and
from running dinit on a workstation.  This runs the real thing: a
nix2container image whose entrypoint is `containerWrapper`, under podman, in a
guest that is not this machine.

Eight claims, in the order they can fail:

    init      dinix-init makes the directories a service needs, on mounts
              that arrive 1777
    keygen    the sshd-keygen service runs before sshd, with no shell in
              the image
    login     sshd accepts a key and runs a command, so the user database,
              the privilege separation user and the generated host key are
              all in place
    buffer    a service logging to a buffer stays out of the collected
              stream, and its output is in the buffer
    privsep   /var/empty ends up 0755, which is the mode sshd refuses to
              start without
    critical  stopping a critical service stops the container
    mustExist the same image, run without the one volume it asks for,
              stops and names the path
    symlink   dinix-init refuses a symlink planted where a dirs entry goes,
              rather than chowning whatever it points at
    sigterm   SIGTERM stops the container well inside a grace period

The container is given the shape Kubernetes gives one: a read-only root
filesystem, tmpfs where something must be written, and the user database
mounted a file at a time.

The same script runs twice, against two images, because sshd decides by its
own uid whether it separates privileges.  `vms.settings` carries the
difference: as root, and as an ordinary user with `--user`.
"""

import re

from uml_runner import Machine, MachineError, Machines, run_test
from uml_runner.cluster import until

NAME = "dinix"

# What the buffered service writes.  It must not appear in `podman logs`.
MARKER = "dinix-buffer-marker"

# podman kills a container that has not stopped within its own default of 10s,
# and Kubernetes waits 30.  Either is a long way from what dinit needs, so a
# figure anywhere near them means SIGTERM is not being handled.
STOP_BUDGET_MS = 5000

# The files a container gets from dinix, mounted one at a time.  A volume over
# /etc would hide the /etc/hosts and /etc/resolv.conf the runtime puts there.
ETC = ["passwd", "group", "shadow", "nsswitch.conf"]


def run_args(
    settings: dict,
    name: str = NAME,
    tmpfs: list[str] | None = None,
    volumes: tuple[str, ...] = (),
) -> str:
    mounts = [
        f"--volume {settings['configDir']}/etc/{etc}:/etc/{etc}:ro" for etc in ETC
    ] + [f"--volume {volume}" for volume in volumes]
    # podman gives a tmpfs mode 1777, which is what makes these worth mounting:
    # dinix-init is the thing that turns them into the modes sshd insists on.
    paths = settings["tmpfs"] if tmpfs is None else tmpfs
    tmpfs_args = [f"--tmpfs {path}" for path in paths]
    return " ".join(
        [
            f"--name {name}",
            # The guest's own network. netavark and nftables are not what this
            # test is about, and the container's port is not 22.
            "--network host",
            "--read-only",
            *tmpfs_args,
            *mounts,
            # Empty when the container runs as root, which is podman's default.
            settings["podmanUser"] and f"--user {settings['podmanUser']}",
        ]
    ).strip()


async def ssh(vm: Machine, settings: dict, command: str) -> str:
    # -F none, because the guest's /etc/ssh/ssh_config includes a drop-in from
    # the store, and the store reaches the guest over hostfs with the uid of
    # whoever ran the kernel. ssh then calls it "Bad owner or permissions" and
    # refuses to start. Nothing to do with the container.
    # 2>&1 because the agent captures standard output alone, and every reason
    # ssh has for failing is on standard error. So is anything sshd says about
    # the session -- "Could not chdir to home directory" for one, since a
    # read-only image has no home.
    return await vm.succeed(
        "ssh -F none -i /tmp/dinix-test-key"
        " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        " -o ConnectTimeout=5 -o LogLevel=ERROR"
        f" -p {settings['port']} {settings['loginUser']}@127.0.0.1 {command!r} 2>&1",
        timeout=120,
    )


# What a remote command answered, marked so that nothing else on the stream
# can be mistaken for it.
#
# The alternative, reading the last line, is wrong on a stream that carries
# two things: the command's own output and whatever sshd says about the
# session, merged by the 2>&1 above. A session message arriving after the
# answer then *is* the last line. Measured on a runner, where a CA bundle the
# container could read was reported as one it could not.
ANSWER = re.compile(r"dinix-answer\[(.*)\]")


def last_line(output: str) -> str:
    """The last line of a guest command's output. Not for ssh -- see `answer`."""
    lines = output.strip().splitlines()
    return lines[-1].strip() if lines else ""


async def answer(vm: Machine, settings: dict, command: str) -> str:
    # Double quotes only: ssh() passes the command through repr(), which
    # chooses single quotes unless the string holds one.
    output = await ssh(vm, settings, f'printf "dinix-answer[%s]\\n" "$({command})"')
    found = ANSWER.findall(output)
    if not found:
        raise MachineError(
            f"[{vm.name}] {command!r} answered nothing over ssh:\n{output}"
        )
    return found[-1].strip()


async def test(vms: Machines) -> None:
    node = vms.node
    settings = vms.settings
    shape = "as an ordinary user" if settings["podmanUser"] else "as root"
    print(f"[test] the container runs {shape}", flush=True)

    # A private key in the store is world-readable, and ssh refuses a key it
    # owns with any other bit set.  Copy it out rather than loosen the check.
    # The public half as well: ssh sends it to offer the key, and reads it from
    # a file beside the private one.
    await node.succeed(
        f"install -m 600 {settings['clientKey']}/id_ed25519 /tmp/dinix-test-key"
    )
    await node.succeed(
        f"install -m 644 {settings['clientKey']}/id_ed25519.pub /tmp/dinix-test-key.pub"
    )

    await node.succeed(settings["copyToPodman"], timeout=900)
    images = await node.succeed("podman images --format '{{.Repository}}:{{.Tag}}'")
    if settings["imageRef"] not in images:
        raise MachineError(f"[{node.name}] {settings['imageRef']} is not loaded:\n{images}")
    print(f"[test] podman has {settings['imageRef']}", flush=True)

    await node.succeed(
        f"podman run --detach {run_args(settings)} {settings['imageRef']}",
        timeout=300,
    )

    async def answered() -> tuple[bool, str]:
        code, out = await node.execute(
            f"ssh-keyscan -p {settings['port']} -T 2 127.0.0.1", timeout=30
        )
        return code == 0 and "ssh-" in out, out.strip() or "(nothing yet)"

    try:
        await until(f"sshd to answer on port {settings['port']}", answered, 180, node)
    except Exception:
        logs = await node.succeed(f"podman logs {NAME}")
        raise MachineError(
            f"[{node.name}] sshd never answered.\n--- container log ---\n{logs}"
        ) from None

    # The user database reached the container. sshd calls a real account an
    # "invalid user" when it did not, which names neither the mount nor the
    # file, so check it here where the message can.
    passwd = await node.succeed(f"podman exec {NAME} /bin/cat /etc/passwd")
    if f":{settings['uid']}:" not in passwd:
        raise MachineError(
            f"[{node.name}] /etc/passwd in the container has no uid "
            f"{settings['uid']} to log in as:\n{passwd}"
        )
    nsswitch = await node.succeed(f"podman exec {NAME} /bin/cat /etc/nsswitch.conf")
    print(f"[test] the container reads its own user database:\n{passwd}{nsswitch}", flush=True)

    logs = await node.succeed(f"podman logs {NAME}")
    print(f"[test] the container's own log:\n{logs}", flush=True)

    # The keygen service ran, and dinix-init made the directory it wrote into.
    if "generating new host keys" not in logs:
        raise MachineError(
            f"[{node.name}] sshd-keygen said nothing on the collected stream, "
            f"so either it did not run or its output went elsewhere:\n{logs}"
        )

    # A buffer service keeps its output out of the stream the runtime collects,
    # and dinitctl catlog is where it goes instead. Both halves matter: absent
    # from one and present in the other.
    if MARKER in logs:
        raise MachineError(
            f"[{node.name}] a service with dinix.log = \"buffer\" reached the "
            f"collected stream, which is the one place it must not:\n{logs}"
        )
    buffered = await node.succeed(
        f"podman exec {NAME} {settings['dinitctl']} catlog chatty 2>&1", timeout=120
    )
    if f"DINIX_MARKER={MARKER}" not in buffered:
        raise MachineError(
            f"[{node.name}] the buffer holds no output either, so it was "
            f"discarded rather than kept -- or dinit's env-file never reached "
            f"the service:\n{buffered}"
        )
    print("[test] buffered output stayed out of the stream and in the buffer", flush=True)

    # The CA bundle reaches a service by environment, which is the whole point
    # of naming it that way: no mount, and no writable filesystem.
    if f"SSL_CERT_FILE={settings['caBundle']}" not in buffered:
        raise MachineError(
            f"[{node.name}] no service sees SSL_CERT_FILE={settings['caBundle']}, "
            f"so a program falling back to a compiled-in path finds no "
            f"certificates:\n{buffered}"
        )
    # The login goes first, because every check below asks its question over
    # ssh and a refused login answers all of them the same way. Measured by
    # getting it wrong: with the CA bundle asked first, a login that failed on
    # a runner was reported as a certificate the container could not read.
    try:
        who = await answer(node, settings, "id -u")
    except MachineError as refused:
        logs = await node.succeed(f"podman logs {NAME}")
        raise MachineError(f"{refused}\n--- container log ---\n{logs}") from None
    if who != str(settings["uid"]):
        logs = await node.succeed(f"podman logs {NAME}")
        raise MachineError(
            f"[{node.name}] logged in, but as {who!r} and not {settings['uid']}"
            f"\n--- container log ---\n{logs}"
        )
    print(f"[test] a key login reached a command, as uid {settings['uid']}", flush=True)

    exists = await answer(node, settings, f"test -r {settings['caBundle']}; echo $?")
    if exists != "0":
        # What the container sees, not what the store holds: the bundle is
        # 0444 in every nixpkgs, so a container that cannot read it is being
        # shown something else -- a path the image never carried, or a store
        # the guest mounts differently for this account.
        seen = await ssh(
            node,
            settings,
            f"id; ls -ldL {settings['caBundle']} || true; "
            f"ls -ld /nix/store || true; echo $?",
        )
        raise MachineError(
            f"[{node.name}] SSL_CERT_FILE names {settings['caBundle']}, which the "
            f"container cannot read:\n{exists}\n--- as the container sees it ---\n{seen}"
        )
    print("[test] every service is told where the CA bundle is, and it is there", flush=True)

    # /var/empty arrived 1777 from --tmpfs, and sshd refuses to start when it
    # is group or world writable. It started, so dinix-init fixed it; check the
    # mode itself rather than infer it. A container that is not root separates
    # no privileges and has no such directory.
    if "/var/empty" in settings["tmpfs"]:
        mode = await answer(node, settings, "stat -c %a /var/empty")
        if mode != "755":
            raise MachineError(f"[{node.name}] /var/empty is mode {mode!r}, not 755")
        print("[test] dinix-init turned a 1777 tmpfs into 0755", flush=True)
    else:
        missing = await answer(node, settings, "test -e /var/empty; echo $?")
        if missing == "0":
            raise MachineError(
                f"[{node.name}] /var/empty exists, so dinix made a privilege "
                f"separation directory a rootless sshd never asks for"
            )
        print("[test] a rootless container gets no /var/empty", flush=True)

    # Stopping a critical service must stop dinit, and so the container.
    # --force because boot depends on sshd, and dinitctl refuses to stop a
    # service with hard dependents without it. It goes after the command, not
    # before: dinitctl takes general options first and command options second.
    #
    # execute and not succeed: this command asks the container to go away, and
    # when it does the exec'd dinitctl goes with it. Measured at exit 137 --
    # killed -- as often as at 0, which is a race and not a result. The
    # assertion is the wait below; a dinitctl that failed for a real reason
    # leaves the container running and times out there.
    await node.execute(
        f"podman exec {NAME} {settings['dinitctl']} stop --force sshd 2>&1", timeout=120
    )
    status = (await node.succeed(f"podman wait --condition exited {NAME}", timeout=120)).strip()
    # dinit ends in an unconditional return EXIT_SUCCESS, so this is 0 whatever
    # stopped it. See Lillecarl/dinix#9.
    if status != "0":
        raise MachineError(f"[{node.name}] the container exited {status}, and dinit only exits 0")
    print("[test] stopping the critical service stopped the container", flush=True)

    await node.succeed(f"podman rm --force {NAME}")

    # The same image, with the one volume mustExist asks for taken away. An
    # unmounted volume otherwise surfaces as whichever service touches the path
    # first, failing in its own vocabulary; this is the message that names the
    # path instead. In the foreground, because dinit always exits 0 and so the
    # exit code says nothing -- what is being checked is what it said.
    without = [path for path in settings["tmpfs"] if path != settings["mustExist"]]
    _, refused = await node.execute(
        f"podman run --rm {run_args(settings, 'dinix-nomount', without)}"
        f" {settings['imageRef']} 2>&1",
        timeout=300,
    )
    if f"{settings['mustExist']} must exist and does not" not in refused:
        raise MachineError(
            f"[{node.name}] a container missing {settings['mustExist']} did not say "
            f"so and stop:\n{refused}"
        )
    print(f"[test] a container without {settings['mustExist']} stopped and named it", flush=True)

    # A symlink planted where a dirs entry goes. create_dir_all is happy with
    # one, and both set_permissions and chown follow it, so dinix-init has to
    # look and refuse.
    #
    # It points at a directory that exists, which is the attack: a dangling
    # symlink stops create_dir_all at EEXIST, so dinix-init refuses that one
    # without ever reaching the check being tested here.
    await node.succeed("rm -rf /tmp/planted && mkdir -p /tmp/planted")
    await node.succeed("ln -s /run /tmp/planted/logs")
    await node.succeed("chmod 0755 /tmp/planted")
    _, planted = await node.execute(
        f"podman run --rm {run_args(settings, 'dinix-planted', without, ('/tmp/planted:/data',))}"
        f" {settings['imageRef']} 2>&1",
        timeout=300,
    )
    if "is a symlink, refusing to touch its target" not in planted:
        raise MachineError(
            f"[{node.name}] dinix-init followed a planted symlink instead of "
            f"refusing it:\n{planted}"
        )
    print("[test] dinix-init refused a planted symlink", flush=True)

    # How long a pod deletion waits. podman sends SIGTERM and kills at its own
    # default of 10s, so this is measured in the guest rather than across the
    # agent, where a round trip would be most of the number.
    await node.succeed(
        f"podman run --detach {run_args(settings, 'dinix-term')} {settings['imageRef']}",
        timeout=300,
    )

    async def running() -> tuple[bool, str]:
        code, out = await node.execute(
            f"podman exec dinix-term {settings['dinitctl']} list 2>&1", timeout=60
        )
        return code == 0, out.strip() or "(no control socket yet)"

    await until("dinit to answer on its control socket", running, 120, node)
    elapsed = await node.succeed(
        "start=$(date +%s%3N)"
        " && podman stop --time 30 dinix-term > /dev/null"
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
    await node.succeed("podman rm --force dinix-term")


run_test(test)
