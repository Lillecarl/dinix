# dinix

Build [dinit](https://davmac.org/projects/dinit) service configurations with
the NixOS module system.

dinix renders a services directory, checks it with `dinit-check` at build time,
and wraps `dinit` so it finds that directory with no arguments. The main use is
supervising several processes inside one container image built from a Nix
closure.

## Try it

This serves "Hello World" on port 8080:

```
nix run --file . config.userWrapper -- --user
```

## Entry point

`default.nix` takes your own `pkgs` and your own modules:

```nix
import ./dinix {
  inherit pkgs;
  modules = [ ./my-services.nix ];
}
```

It returns `{ pkgs, lib, eval, options, config }`. The two outputs to build are
`config.userWrapper` and `config.containerWrapper`.

Nothing here does import-from-derivation, so it is safe to evaluate inside a
larger configuration.

## Services

`services.<name>` accepts every setting in
[DINIT-SERVICE(5)](https://davmac.org/projects/dinit/man-pages-html/dinit-service.5.html).
A setting the manual writes with a colon, such as `depends-on:`, takes a Nix
list here, and each element becomes its own line. Everything else becomes
`name = value`. Values are converted to strings, and a boolean becomes `true`
or `false`.

`command` and `stop-command` accept a derivation. dinix uses `meta.mainProgram`
when the derivation has one, and the store path itself otherwise, so both
`writeShellApplication` and `writeShellScript` work.

```nix
services.nginx = {
  command = pkgs.writeShellApplication { name = "nginx"; text = "exec nginx -g 'daemon off;'"; };
  depends-on = [ "database" ];
  dinix.critical = true;
};
```

## Running in a container

A container runtime restarts a container when its PID 1 exits. So a service
tree has to say which services must take the container down with them.

**dinit always exits 0.** It has no mechanism for reporting that a service
failed; `dinit.cc` ends in an unconditional `return EXIT_SUCCESS`. A critical
service that fails to start still stops the container, and the container still
restarts under `restartPolicy: Always`, which is the common case. But under
`restartPolicy: OnFailure`, in a Job, or under a `docker run` whose caller reads
the status, a failed service reads as a clean success and nothing retries.
Measured against dinit 0.22.1.

`services.<name>.dinix.critical` decides that, by choosing how the service
attaches to dinit's `boot` service:

| value | effect |
| --- | --- |
| `true` | `boot` depends on it. It stops, every service stops, dinit exits. |
| `false` | `boot` waits for it. It can crash and restart forever. |
| `null` | No attachment. Write `services.boot.depends-on` yourself. Default. |

Three things measured against dinit 0.22.1, none of them obvious:

- `boot` gets `restart = false` as soon as one critical service exists. dinit
  restarts everything by default, so otherwise `boot` comes back up, drags the
  dead service with it, and dinit never exits.
- `restart = true` on a critical service is still safe. Stopping `boot` stops
  the service first, so its own restart setting never applies.
- `smooth-recovery` cancels criticality. It restarts the process without
  stopping dependents, so `boot` never stops.

A service that `boot` only waits for gets `restart-limit-count = 0` and
`restart-delay = 5`. dinit otherwise gives up after 3 restarts in 10 seconds
and retries 200ms apart.

SIGTERM to `dinit --container` stopped two services and exited in 6ms, so a
pod deletion does not wait out its grace period. `podman stop` to exited, in a
container in the test guest, measured 0.8s as an ordinary user and 2.0s as
root — that figure is mostly podman's own work, not dinit's, and both are a
long way from podman's 10s kill and Kubernetes' 30s default.

### Logging

A container runtime collects the output of PID 1 and nothing else, so each
service has to say whether it joins that stream. `dinix.log` decides:

| value | renders | for |
| --- | --- | --- |
| `console` | `options: shares-console` | reaching the log collector. The default for process-like services. |
| `buffer` | `log-type = buffer` | a service too chatty for that stream |
| `file` | `log-type = file` | an application that insists on its own file. The default when `logfile` is set. |
| `none` | nothing | discarding the output, which is dinit's own default |

Output on the console passes through unchanged. dinit adds no prefix, so a
service emitting JSON lines stays parseable.

**`buffer` is the only destination that needs no rotation.** It keeps the last
`logBufferSize` bytes in memory, readable with `dinitctl catlog <service>`, and
a ring buffer cannot grow without bound. dinit's own default size is 4096
bytes, which holds almost nothing; dinix uses 256 KiB.

**dinit does not rotate `logfile`, and it grows without bound.** Whatever owns
that volume owns the rotation. Prefer talking the application into writing to
standard error — most have a switch for it, and finding it beats building
machinery.

Set `dinix.log` rather than `log-type`: `log-type` follows from it, and
dinit ignores a log type on a service that shares the console.

**Do not check `/proc/<pid>/environ` to see whether an env-file arrived.**
php-fpm and nginx rewrite their own environment to set the process title, so
that file reads back empty for the master and every worker, which is
indistinguishable from a variable that was never set. `/proc/1/environ` is no
help either: it shows what the container was started with, not the env-file.
Read the variable from inside the process instead, or test with a program that
leaves its environment alone.

`quiet` drops dinit's own `[  OK  ]` status lines, which otherwise share the
stream with service output. `consoleLevel` defaults to `warn`, which keeps the
line naming the service that brought the container down.

### Services that write their own log files

Some applications keep their own files and cannot be pointed at standard error.
`dinix.logDir` declares that, without changing what dinit does:

```nix
services.phd = {
  dinix.logDir = "/var/lib/phabricator/phd/log";
  dinix.logDirSize = "64Mi";
};
```

Everything so declared appears in the top-level `logDirs`, keyed by service.
Read it when building the container so the volume and its limit come from the
service definition, instead of a second list kept in step by hand.

### The control socket

`socketPath` defaults to `/run/dinitctl`, dinit's own compiled-in path.

**dinit exits 1 at startup when it cannot create this socket.** On a read-only
root filesystem it must name a writable volume. Under Kubernetes that is
wherever an `emptyDir` is mounted. `/dev` does not serve: the kubelet creates
it mode 755 owned by root, so a container running as a normal user cannot write
there.

`containerWrapper` puts `DINIT_SOCKET_PATH` on its `dinitctl` and
`dinit-monitor`, so both work from an absolute store path with an empty
environment.

### Directories, and checking what should already be there

A Nix build cannot `chown`, so a directory that needs an owner or a mode has to
be made at startup. `dirs` does that:

```nix
dirs."/run/sshd" = { mode = "0755"; uid = 0; gid = 0; };
mustExist."/data" = { kind = "dir"; };
```

`mustExist` creates nothing. It checks, and stops the container when the check
fails. That is for what a volume is supposed to provide: an unmounted volume
otherwise surfaces as whichever service touches the path first, failing in its
own vocabulary. Checks run before `dirs` is made.

Both are done by `dinix-init`, a small Rust binary in this repository:

- **413 KiB, one store path, statically linked, no dependencies.**
- **It cannot run a program.** There is no `exec` step and there must never be
  one; that is the whole reason it exists instead of a shell. Unknown steps are
  rejected rather than ignored.
- It refuses to touch a symlink. `create_dir_all` succeeds on a symlink to a
  directory, and both `set_permissions` and `chown` follow symlinks, so
  anything able to plant one could otherwise choose what got chowned.
- Owners are numeric. This runs before the services do, so the user database
  may not be in place yet and a name would be a lookup that cannot be relied on.

Setting either option adds a `dinix-init` service that `boot` depends on, and
every other service gets `after: dinix-init`. Without the `after`, `boot` would
start `dinix-init` and the critical services together.

### Users

`users.files` is a store path holding `etc/passwd`, `etc/group`, `etc/shadow`
and `etc/nsswitch.conf`, as real files rather than symlinks. Mount those into a
container one file at a time: a volume over `/etc` hides the `/etc/hosts` and
`/etc/resolv.conf` the runtime puts there and takes out name resolution.

**Under Kubernetes, a file at a time means `subPath`, and a `subPath` mount
never updates.** The kubelet refreshes whole-directory mounts only: "A
container using a ConfigMap as a `subPath` volume mount will not receive
updates when the ConfigMap changes." So mounting the user database a file at a
time and rotating it without restarting the pod cannot both be true. Restart
the pod, or mount a directory somewhere harmless and symlink into it.

**No shadow entry can match a password, and there is no option to set a hash.**
Nix normalises store permissions to world-readable, so a hash here would be a
hash published to every user and process on the host. Mount a real shadow file
over this one if an account has to log in with a password.

The field is `*`, not the `!` that `passwd -l` writes. Both refuse every
password. But OpenSSH on Linux compiles in `!` as its locked-account marker,
and with PAM off it then refuses the account outright — key login included,
with `User root not allowed because account is locked`. Measured against
OpenSSH 10.5p1, `platform.c`.

A process calling `getpwuid` on its own uid fails outright when that uid is
missing from passwd, so the content matters even where nothing reads the file.

`users.installAtRuntime` writes the database into the root filesystem at
startup instead. It is off by default, and turning it on makes
`containerWrapper` a shell script with rsync and coreutils in its closure.

## OpenSSH

`openssh.enable` renders `sshd_config`, adds an `sshd` service, and supplies
the three things sshd needs from the system around it. It is the first service
dinix owns, so the options sit beside `users` rather than under `services`,
which holds dinit service descriptions.

```nix
openssh = {
  enable = true;
  hostKeys = [ "/keys/ssh_host_ed25519_key" ];
  settings.PermitRootLogin = "prohibit-password";
};
services.sshd.dinix.critical = true;
```

`settings` is one attribute per `sshd_config` keyword. A keyword that may
repeat, `HostKey` and `Port` among them, takes a list and becomes one line for
each element.

**Host keys are mounted, not built.** A key is a secret, and everything in the
Nix store is readable by every process on the host. Each path in `hostKeys`
also becomes a `mustExist` check, so a volume that is not mounted stops the
container with the path in the message.

**The mode has to be 0400 or 0600.** sshd checks the mode of a private key
only when the file belongs to the user running sshd — which in a container is
root, and so is the file. A Kubernetes secret arrives 0644 unless
`defaultMode` says otherwise, and a store path is 0444. Both fail: sshd prints
`UNPROTECTED PRIVATE KEY FILE`, ignores the key, and then exits because it has
none. Measured against OpenSSH 10.5p1, `authfile.c`.

`openssh.generateHostKeys.enable` makes them at startup instead, with an
`sshd-keygen` service that `sshd` depends on. `ssh-keygen -A` makes a key of
every type that has none, so it is one exec with no shell and it is safe to
run again. Two things to know: `-f` takes a **prefix**, not a directory, so
keys land in `<root>/etc/ssh/`; and on a volume that keeps nothing the host
identity changes at every restart, which a client that remembers the old one
refuses to connect to.

dinix also writes the `sshd` account into the user database and makes
`/var/empty` mode 0755 owned by root. Both are conditions sshd checks itself
and exits over: the privilege separation user name is compiled in, and the
privilege separation directory must not be writable by group or others. A
Kubernetes `emptyDir` and a `podman --tmpfs` both arrive 1777, so the mode is
set rather than assumed.

`services.sshd.dinix.critical` defaults to `false`, which starts sshd and lets
it crash and restart without taking the container down. Set it to `true` where
sshd is the reason the container exists.

**An ssh container needs a shell, and dinix does not put one there.** sshd runs
the login shell named in `passwd`, and then looks for the command on a PATH of
`/usr/bin:/bin:/usr/sbin:/sbin` that it compiles in. A Nix closure has none of
those, so a login succeeds and then every command fails. Put busybox or
coreutils at `/bin` in the image, or point the account's `shell` at a store
path. Nothing dinix runs itself needs this.

### sshd without root

`openssh.rootless = true` is the shape for a container that must not run as
root. sshd decides this by its own uid rather than by configuration, so the
option tells dinix which shape to render. Measured against OpenSSH 10.5p1 by
running both:

- **A rootless sshd serves one account: its own.** It cannot change uid, so it
  accepts the login and then exits with `Failed to set uids`. The client sees
  the connection reset.
- It needs no privilege separation, so dinix writes no `sshd` account and does
  not make `/var/empty`. sshd asks for neither when its uid is not 0.
- **It cannot bind below port 1024.** The default port becomes 2222, and dinix
  refuses a privileged port rather than letting sshd fail at startup.
- A host key it does not own escapes the mode check above, because sshd only
  checks a key belonging to the user running it. A root-owned store path
  therefore loads. That is not a reason to put a key in the store, which
  publishes it to every process on the host.

Add that one account to `users.users` with the uid the container runs as. sshd
calls `getpwnam` on the login name and reports `invalid user` when it finds
nothing, which names neither the uid nor the file. dinix writes root and nobody
and no one else.

## One store path, or several

Everything dinix generates goes into a single store path, `configDir`:

```
services/<name>   service descriptions
env/<name>        per-service environment files
env-file          the environment file dinit itself reads
init.spec         the directories and checks for dinix-init
etc/              passwd, group, shadow, nsswitch.conf, sshd_config
```

A container image built from a Nix closure usually gets a layer per store path,
and image formats have a layer ceiling. The pieces above all change together,
so spending several layers on them buys nothing. Measured with nix2container on
a configuration with two services, two per-service environment files, a
directory and a check:

| | layers | size |
| --- | --- | --- |
| `consolidateConfig = true` | **14** | 51 MB |
| `consolidateConfig = false` | 18 | 51 MB |

Same bytes, four fewer layers.

A service refers to its environment file as `../env/<name>`, which dinit
resolves against the directory holding the description, so the reference stays
inside the path. The one file that has to name the path it lives in, the
`dinix-init` service description, gets it substituted at build time — no Nix
expression can know a store path before it is built.

Set `consolidateConfig = false` where store paths are not layers, such as a
runtime that mounts the closure directly. Each piece is then its own path, and
changing one service does not rebuild the rest.

`dev.nix` builds both images and reports on them. It is not imported by
`default.nix`, so nix2container never reaches a consumer's closure:

```
nix run --file ./dev.nix report
```

## Outputs

`containerWrapper` is dinit as PID 1, reading its services straight from the
store. It is a plain binary wrapper, so the image needs no shell and no
writable root filesystem. `meta.mainProgram` is `dinit`, so `lib.getExe`
resolves it and the whole path symlinks into a larger environment.

`userWrapper` is dinit, `dinit-check`, `dinitctl` and `dinit-monitor` for
running a configuration as an unprivileged user.

`verifyConfig` runs `dinit-check` over the rendered services as part of the
build, so a bad configuration fails the build rather than the container. It is
on by default.

## Tests

`dinit-check` reads a configuration. It cannot say whether the container comes
up. That takes running one:

```
nix build --file ./dev.nix containerTest rootlessTest   # in a build sandbox
nix run   --file ./dev.nix containerTest.run            # outside it
```

The test boots a guest with
[user-mode-nixos](https://github.com/Lillecarl/user-mode-nixos), runs podman in
it, loads the nix2container image whose entrypoint is `containerWrapper`, and
asserts against the running container. The guest kernel is User-Mode Linux, so
this needs no KVM, no root and no tap devices, and the default form runs inside
a Nix build sandbox.

The container gets the shape Kubernetes gives one: a read-only root filesystem,
a tmpfs where something has to be written, and the user database mounted a file
at a time. `tests/openssh.py` is the script and `tests/container.nix` is the
configuration under test.

It runs twice against two images, because sshd decides by its own uid whether
it separates privileges and dinix renders a different configuration for each.
`rootlessTest` adds `tests/rootless.nix` and `podman run --user 1000:1000`, and
checks that the login arrives as uid 1000 and that no `/var/empty` was made.

Eight claims, each one something this file used to assert without evidence:
`dinix-init` makes its directories on mounts that arrive 1777; `sshd-keygen`
runs before sshd with no shell in the image; a key login reaches a command; a
`buffer` service stays out of the collected stream and its output is in the
buffer; `/var/empty` ends up 0755; stopping a critical service stops the
container; the same image without the volume `mustExist` names stops and says
which; `dinix-init` refuses a symlink planted where a `dirs` entry goes; and
SIGTERM stops the container well inside a grace period.
