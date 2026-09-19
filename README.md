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
pod deletion does not wait out its grace period.

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

### Users

`users.files` is a store path holding `etc/passwd`, `etc/group`,
`etc/nsswitch.conf` and an empty `var/empty`. Mount those into a container one
file at a time: a volume over `/etc` hides the `/etc/hosts` and
`/etc/resolv.conf` the runtime puts there and takes out name resolution.

A process calling `getpwuid` on its own uid fails outright when that uid is
missing from passwd, so the content matters even where nothing reads the file.

`users.installAtRuntime` writes the database into the root filesystem at
startup instead. It is off by default, and turning it on makes
`containerWrapper` a shell script with rsync and coreutils in its closure.

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
