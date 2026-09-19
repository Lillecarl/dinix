#!/usr/bin/env python3
"""Does a dinix container actually work?

Everything dinix claims about a container is argued from dinit's source and
from running dinit on a workstation.  This runs the real thing: a
nix2container image whose entrypoint is `containerWrapper`, under podman, in a
guest that is not this machine.

Five claims, in the order they can fail:

    init      dinix-init makes the directories a service needs, on mounts
              that arrive 1777
    keygen    the sshd-keygen service runs before sshd, with no shell in
              the image
    login     sshd accepts a key and runs a command, so the user database,
              the privilege separation user and the generated host key are
              all in place
    privsep   /var/empty ends up 0755, which is the mode sshd refuses to
              start without
    critical  stopping a critical service stops the container

The container is given the shape Kubernetes gives one: a read-only root
filesystem, tmpfs where something must be written, and the user database
mounted a file at a time.

The same script runs twice, against two images, because sshd decides by its
own uid whether it separates privileges.  `vms.settings` carries the
difference: as root, and as an ordinary user with `--user`.
"""

from uml_runner import Machine, MachineError, Machines, run_test
from uml_runner.cluster import until

NAME = "dinix"

# The files a container gets from dinix, mounted one at a time.  A volume over
# /etc would hide the /etc/hosts and /etc/resolv.conf the runtime puts there.
ETC = ["passwd", "group", "shadow", "nsswitch.conf"]


def run_args(settings: dict) -> str:
    mounts = [
        f"--volume {settings['configDir']}/etc/{name}:/etc/{name}:ro" for name in ETC
    ]
    # podman gives a tmpfs mode 1777, which is what makes these worth mounting:
    # dinix-init is the thing that turns them into the modes sshd insists on.
    tmpfs = [f"--tmpfs {path}" for path in settings["tmpfs"]]
    return " ".join(
        [
            f"--name {NAME}",
            # The guest's own network. netavark and nftables are not what this
            # test is about, and the container's port is not 22.
            "--network host",
            "--read-only",
            *tmpfs,
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
    # read-only image has no home -- which is why callers read the last line
    # rather than the whole output.
    return await vm.succeed(
        "ssh -F none -i /tmp/dinix-test-key"
        " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        " -o ConnectTimeout=5 -o LogLevel=ERROR"
        f" -p {settings['port']} {settings['loginUser']}@127.0.0.1 {command!r} 2>&1",
        timeout=120,
    )


def last_line(output: str) -> str:
    lines = output.strip().splitlines()
    return lines[-1].strip() if lines else ""


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

    try:
        who = await ssh(node, settings, "id -u")
    except MachineError as refused:
        logs = await node.succeed(f"podman logs {NAME}")
        raise MachineError(f"{refused}\n--- container log ---\n{logs}") from None
    if last_line(who) != str(settings["uid"]):
        raise MachineError(
            f"[{node.name}] logged in, but as {who!r} and not {settings['uid']}"
        )
    print(f"[test] a key login reached a command, as uid {settings['uid']}", flush=True)

    # /var/empty arrived 1777 from --tmpfs, and sshd refuses to start when it
    # is group or world writable. It started, so dinix-init fixed it; check the
    # mode itself rather than infer it. A container that is not root separates
    # no privileges and has no such directory.
    if "/var/empty" in settings["tmpfs"]:
        mode = await ssh(node, settings, "stat -c %a /var/empty")
        if last_line(mode) != "755":
            raise MachineError(f"[{node.name}] /var/empty is mode {mode!r}, not 755")
        print("[test] dinix-init turned a 1777 tmpfs into 0755", flush=True)
    else:
        missing = await ssh(node, settings, "test -e /var/empty; echo $?")
        if last_line(missing) == "0":
            raise MachineError(
                f"[{node.name}] /var/empty exists, so dinix made a privilege "
                f"separation directory a rootless sshd never asks for"
            )
        print("[test] a rootless container gets no /var/empty", flush=True)

    # Stopping a critical service must stop dinit, and so the container.
    # --force because boot depends on sshd, and dinitctl refuses to stop a
    # service with hard dependents without it. It goes after the command, not
    # before: dinitctl takes general options first and command options second.
    await node.succeed(
        f"podman exec {NAME} {settings['dinitctl']} stop --force sshd 2>&1", timeout=120
    )
    status = (await node.succeed(f"podman wait --condition exited {NAME}", timeout=120)).strip()
    # dinit ends in an unconditional return EXIT_SUCCESS, so this is 0 whatever
    # stopped it. See Lillecarl/dinix#9.
    if status != "0":
        raise MachineError(f"[{node.name}] the container exited {status}, and dinit only exits 0")
    print("[test] stopping the critical service stopped the container", flush=True)

    await node.succeed(f"podman rm --force {NAME}")


run_test(test)
