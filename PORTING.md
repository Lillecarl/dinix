# Before porting: is it already a modular service?

[Modular Services](https://nixos.org/manual/nixos/unstable/#modular-services)
are nixpkgs' portable service modules — a module says what to run without
saying who runs it, so one module works under systemd, under finit and under
dinit. dinix implements the interface; see the `system.services` option.

```nix
system.services.tunnel = {
  imports = [ pkgs.ghostunnel.services.default ];
  ghostunnel.listen = "127.0.0.1:8443";
  dinit.service.dinix.critical = true;
};
```

**If a service already ships one, use it and port nothing.** `pkgs.<name>.services.default`
is where it lives. About ten exist today, `php` among them, and the number
grows.

If none exists, consider writing one upstream rather than a dinix-only module:
it is the same work and everyone gets it. What it cannot express yet is the
part our ports lean on — no user is created, no directory is made, nothing is
owned, and there is no run-once init — so a module that needs those still
needs a dinix-specific tree beside it. The interface is new in NixOS 25.11 and
changing, so track it rather than wrap it.

# Porting a service from services-flake

[services-flake](https://github.com/juspay/services-flake) has about thirty
services written as Nix modules. Their supervisor is process-compose and ours
is dinit, so a port keeps the options and changes the last step. `redis.nix`
and `tests/collections/redis.nix` are the worked example; read them beside
`services-flake/nix/services/redis.nix` and the mapping is visible.

A port is four files, two of which already exist.

## 1. The module

`<service>.nix` at the top of this repository:

```nix
let
  inherit (import ./service-lib.nix) multiService;
in
multiService "redis" (
  { name, config, pkgs, lib, ... }:
  {
    options = {
      # One for one with the services-flake module.
      package = lib.mkPackageOption pkgs "redis" { };
      port = lib.mkOption { type = lib.types.port; default = 6379; };
    };

    config.outputs = {
      dirs.${config.dataDir}.mode = "0700";
      services.${config.serviceName} = {
        type = "process";
        command = "${lib.getExe' config.package "redis-server"} ${configFile}";
        dinix.critical = lib.mkDefault false;
      };
    };
  }
)
```

`multiService` supplies `enable`, `dataDir` and `serviceName`, makes the
option an attribute set of instances, and collects every enabled instance's
`outputs` into the top-level `services`, `dirs` and `mustExist`. Declare the
service's own options and set `outputs`. Nothing else.

Then add the file to `imports` in `options.nix`.

## 2. The collection

`tests/collections/<service>.nix` is an ordinary dinix configuration, plus a
`collection` attribute saying what to ask the running container:

```nix
{ pkgs, config, ... }:
{
  redis.main.enable = true;

  collection = {
    writable = [ config.redis.main.dataDir ];
    checks = [
      {
        name = "redis answers on its TCP port";
        command = "${pkgs.redis}/bin/redis-cli -p 6379 ping";
        expect = "PONG";
      }
    ];
  };
}
```

`dev.nix` finds it by being in that directory. `nix build --file ./dev.nix
collections.<service>.<mode>` runs it in one of four modes — `root` and
`user` containers, and `vm-root` and `vm-user` without containerization —
and a port passes in all four. Nothing else needs editing, and no Python is
written.

`import ./.` answers one attribute per mode — `rootContainer`,
`nobodyContainer`, `noContainer` — for the same modules, so differences
between environments live in the evaluation, where a build either works or
fails loudly. The two vm test modes run the one output without a container
twice: as root and as an ordinary user. {option}`mode` names which output a
configuration is; a collection reads it where privilege differs by mode,
which is run-as and nothing else: only the rootContainer output sets it,
because an unprivileged dinit cannot change user at all.

A data directory defaults to `$DINIX_STATE_DIR/<service>/<instance>`, or
`/var/lib/...` when the variable is unset. The containers run writable, with
a tmpfs for `/run` and one for the state directory, and dinix-init makes the
data directories on it; the vm modes run no dinix-init at all, so the driver
makes the `collection.writable` paths on the guest instead.
Uncontainerized never means the host gets trashed: every path a run creates
sits under the state directory.

`writable` is also the read-only contract: a deployment with a read-only
root mounts exactly these paths — emptyDirs beside `/run`, which dinit needs
for its control socket everywhere — and nothing else the services write to.
Keeping the list complete is what keeps such a deployment working. The test
itself runs writable; it proves the services start and answer, not that they
declare every write.

A check needs a client, and the image holds only what the services reference.
redis-cli rides along in the redis package; most services are not so
accommodating — memcached ships a server only. `collection.packages` takes
extra packages for the image, and the check names the client's absolute store
path. A client that needs a pipe — `printf 'version\r\n' | nc …` — names bash
there too and runs its pipeline through `bash -c`.

Every collection gets these without asking: the image loads, the container
runs, dinit answers on its control socket, every service reaches `started`,
no service failed while the checks ran, and SIGTERM stops the container inside
a grace period.

Two things about a check, both measured by getting them wrong:

- **There is no terminal.** A client that formats for a human when it has one
  prints its raw reply here. `redis-cli exists` gives `0`, not `(integer) 0`.
  Expect the raw form.
- **`expect` is a substring**, so pick one that cannot match by accident. Two
  instances holding different values under the same key prove they are
  separate; a count of `0` proves nothing, because `0` is in `10` as well.

## The mapping

| services-flake | dinix |
| --- | --- |
| `services.<s>.<name>` | `<s>.<name>` |
| `dataDir`, relative to the project | `dataDir`, an absolute path in a container |
| a start script that `mkdir -p`s `dataDir` | `outputs.dirs.<dataDir>` |
| `command = <script>` | `outputs.services.<n>.command`, the program itself |
| `depends_on.<x>.condition` | `depends-on` for hard, `waits-for` for soft |
| `readiness_probe` | a `collection.checks` entry — dinit has no probe |
| `availability.restart = "on_failure"` | `dinix.critical = false` |
| `namespace` | nothing; dinit has no namespaces |

Six things change on the way across, and they are the whole of the work:

- **A state path goes on the command line, never inside a config file.**
  `dataDir` is the literal string `${DINIX_STATE_DIR:-/var/lib}/<svc>/<inst>`,
  and dinit expands it when it loads the service — which is what lets one
  store path run in a container, uncontained and under systemd. dinit
  substitutes `command`, `stop-command`, `working-dir`, `env-file`,
  `pid-file`, `logfile` and `socket-listen`, and nothing else. A config file
  is read by the program, which knows nothing of this and would open a
  directory literally called `${DINIX_STATE_DIR:-/var/lib}`.

  Every service has a way out, and it is the one services-flake already uses:
  a flag (`redis-server --dir`) or a prefix (`nginx -p`, `php-fpm -p`) with
  the paths in the config file left relative. **Check what else the prefix
  moves**: `nginx -p` also moves the default document root, so the port names
  `root` explicitly — found by a 404 rather than by reading.
- **No shell.** services-flake wraps most services in a `writeShellApplication`
  to make a directory and export a variable. dinix makes directories with
  `dirs` before any service starts, and sets variables in `env-file`, so
  `command` is the program itself. A port that still needs a wrapper has found
  something worth saying out loud.
- **The data directory is declared**, not a subdirectory of wherever the
  developer ran the command. Absolute paths throughout, and the collection
  names every path that has to be writable, so a read-only deployment knows
  what to mount. dinix-init makes them from `dirs` before anything starts,
  which is what still puts the modes and owners under test.
- **No readiness probes.** process-compose polls a service until it answers;
  dinit does not. Where services-flake gates a dependent on
  `condition = "process_healthy"`, dinix has `depends-on`, which waits for the
  process to start and no more. A service that must not start before another
  is *ready* needs that readiness expressing some other way — usually the
  program's own flag, sometimes a `scripted` service that blocks.
- **The container runs as root, and some services refuse that.** memcached
  does, and so does postgres's `initdb`. dinit's `run-as` changes user before
  exec, so the process never sees root: the source module's privilege story is
  the collection's to tell, and `nobody` is in the user database dinix writes.
- **Secrets and passwords are mounted**, never rendered into the store.
  Everything dinix generates is world-readable. See the host key note in
  README.md.

## Initialising a data directory once

`initdb` exits 1 on a directory that is not empty — measured — so "initialise
if it has not been initialised" is a conditional. PostgreSQL, MySQL and
MongoDB all want one, and a shell is the usual answer.

Use `dinix-unless` instead, which is {option}`unlessPackage`:

```nix
outputs.services."${config.serviceName}-init" = {
  type = "scripted";
  command = toString [
    (lib.getExe config.unlessPackage)
    "${config.dataDir}/PG_VERSION"          # the marker
    (lib.getExe' config.package "initdb")   # run only if it is absent
    "-D" config.dataDir
  ];
};
outputs.services.${config.serviceName}.depends-on = [ "${config.serviceName}-init" ];
```

It execs the program when the marker is missing and exits 0 when it is there,
so the dependency stays a real one: a first run that genuinely fails still
stops the service that needs it.

It is not a small shell — no `PATH` search, no expansion, no interpretation —
and it is a separate binary from `dinix-init`, which is in every image and
must never be able to run anything. This one reaches only the closures that
name it.

## Licensing

services-flake is Apache-2.0. A ported module keeps a comment at the top
naming the file it came from.
