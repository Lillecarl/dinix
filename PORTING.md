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

If none exists, write one. Every service in `services/` is a modular service,
and the same file would work under systemd or finit. What the interface cannot
express yet is the part our ports lean on — no user is created, no directory is
made and nothing is owned — so a module that needs those carries a
dinix-specific tree beside the portable half. The interface is new in NixOS
25.11 and changing, so track it rather than wrap it. Issue #15 collects what is
missing.

`tests/collections/php-upstream.nix` runs nixpkgs' own php-fpm module
unmodified, beside `tests/collections/phpfpm.nix`, which runs ours. Two things
kept ours: a `php.ini` of one's own, and a pool socket under the state
directory. A path inside a generated configuration file is fixed when the file
is generated, so it cannot be relocatable.

# Porting a service from services-flake or devenv

Two libraries of service modules, and the same port works from either:

- [services-flake](https://github.com/juspay/services-flake),
  `nix/services/<name>.nix`. About thirty services, supervised by
  process-compose.
- [devenv](https://github.com/cachix/devenv), `src/modules/services/<name>.nix`.
  About forty, supervised by process-compose as well. Most of the
  services-flake modules say in their first line that they came from here, so
  read both where both have the service — devenv usually has more options and
  services-flake usually has a test.

Ours is dinit, so a port keeps the options and changes the last step.
`services/redis.nix` and `tests/collections/redis.nix` are the worked example;
read them beside `services-flake/nix/services/redis.nix` and the mapping is
visible.

Two things to check before you spend time on a service:

- **Is the package free, and is it in the cache?** `nix eval --file /etc/nixpkgs
  <pkg>.meta.license` and `nix path-info --store https://cache.nixos.org
  --closure-size --human-readable "$(nix eval --raw --file /etc/nixpkgs <pkg>)"`.
  `dev.nix` takes a plain `import <nixpkgs> { }`, so an unfree or insecure
  package needs a caller to relax its configuration and CI cannot run it.
  Measured: `mongodb` is unfree (SSPL) and `minio` is marked insecure.
- **How big is the closure?** Every mode boots a guest that unpacks it. A
  JVM service is gigabytes, and `checks` already builds thirty of these.

A port is two files, and nothing else is edited.

## 1. The module

`services/<service>.nix`, a modular service:

```nix
# Dependencies arrive through importApply, because a modular service takes no
# pkgs argument.
{ redis }:

{ config, options, lib, ... }:
let
  cfg = config.redis;
in
{
  _class = "service";

  options.redis = {
    # One for one with the services-flake module.
    package = lib.mkOption { type = lib.types.package; default = redis; };
    port = lib.mkOption { type = lib.types.port; default = 6379; };
    dataDir = lib.mkOption { type = lib.types.str; };
  };

  config = {
    process.argv = [ (lib.getExe' cfg.package "redis-server") "--dir" cfg.dataDir ];
  }
  // lib.optionalAttrs (options ? dinit) {
    redis.dataDir = lib.mkDefault config.dinit.stateDir;
    dinit.dirs.${cfg.dataDir}.mode = "0700";
    dinit.service.dinix.critical = lib.mkDefault false;
  };
}
```

`process.argv` is the portable half: what to run, and nothing about who runs
it. Anything dinit-specific goes behind `options ? dinit`, so the module still
evaluates where dinit is absent — that is how upstream's php module carries its
systemd and finit sections.

Under `dinit` the module gets `stateDir`, which is where this service should
keep what it writes, and `dirs`, `mustExist` and `service` — settings written
straight into the dinit service description.

**`config` is `lib.mkMerge [ ... ]` when both halves set the service's own
option.** `//` is a shallow merge, so a `dinit` half setting `redis.dataDir`
replaces a first half setting `redis.extraConfig` outright, and the setting
vanishes with no error. `services/phpfpm.nix` shows the merge form.

A file the program reads is a `configData` entry: the module names the content,
the service manager decides where the file lands, and the module reads the
place back out of `configData.<name>.path`. See `services/nginx.nix`.

A process that belongs to another is a sub-service — `services.init` in
`services/postgres.nix` — which dinix renders as `<service>-<sub>`. A
sub-service is ownership and nothing more: it creates no dependency, so state
the order with `depends-on`.

## 2. The collection

`tests/collections/<service>.nix` is an ordinary dinix configuration, plus a
`collection` attribute saying what to ask the running container. One
`system.services` entry per instance:

```nix
{ pkgs, config, lib, ... }:
let
  redisService = lib.modules.importApply ../../services/redis.nix {
    inherit (pkgs) redis;
  };
  main = config.system.services.redis-main.redis;
in
{
  system.services.redis-main.imports = [ redisService ];

  collection = {
    writable = [ main.dataDir ];
    checks = [
      {
        name = "redis answers on its TCP port";
        command = "${pkgs.redis}/bin/redis-cli -p ${toString main.port} ping";
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

{option}`privileged` says whether dinit will be root, and a collection reads it
where that changes the configuration — which is `run-as` and nothing else,
because an unprivileged dinit cannot change user at all. Whether a run is
containerized is the test driver's business, not the configuration's.

A data directory defaults to {option}`dinit.stateDir`, which is
`$DINIX_STATE_DIR/<service>`, or `/var/lib/<service>` when the variable is
unset. The containers run writable, with
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
| `services.<s>.<name>` | `system.services.<s>-<name>` |
| `dataDir`, relative to the project | `dataDir`, an absolute path in a container |
| a start script that `mkdir -p`s `dataDir` | `dinit.dirs.<dataDir>` |
| `command = <script>` | `process.argv`, the program itself |
| a generated config file | `configData.<name>`, read back as `.path` |
| `depends_on.<x>.condition` | `dinit.service.depends-on`, or `waits-for` for soft |
| `readiness_probe` | a `collection.checks` entry — dinit has no probe |
| `availability.restart = "on_failure"` | `dinit.service.dinix.critical = false` |
| `namespace` | nothing; dinit has no namespaces |

Six things change on the way across, and they are the whole of the work:

- **A state path goes on the command line, never inside a config file.**
  `dataDir` is the literal string `${DINIX_STATE_DIR:-/var/lib}/<service>`,
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
  `process.argv` is the program itself. A port that still needs a wrapper has
  found something worth saying out loud.
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

  **`run-as` is not always the answer.** A program that drops privilege itself
  wants root to begin with, and taking it away first breaks it. php-fpm opens
  its error log by path — `/proc/self/fd/2`, which is dinit's own log — and a
  file dinit made as root refuses the account the service would become:
  `failed to open error_log`, exit 78. Let such a program keep root and use its
  own user directive, as memcached's `-u` and php-fpm's `user` do.
- **Secrets and passwords are mounted**, never rendered into the store.
  Everything dinix generates is world-readable. See the host key note in
  README.md.

## Initialising a data directory once

`initdb` exits 1 on a directory that is not empty — measured — so "initialise
if it has not been initialised" is a conditional. PostgreSQL, MySQL and
MongoDB all want one, and a shell is the usual answer.

Use `dinix-unless` instead, which is {option}`unlessPackage`:

```nix
services.init.process.argv = [
  (lib.getExe dinix-unless)
  "${cfg.pgData}/PG_VERSION"             # the marker
  (lib.getExe' cfg.package "initdb")     # run only if it is absent
  "--pgdata" cfg.pgData
];
services.init.dinit.service.type = "scripted";
dinit.service.depends-on = [ "${name}-init" ];
```

It execs the program when the marker is missing and exits 0 when it is there,
so the dependency stays a real one: a first run that genuinely fails still
stops the service that needs it.

It is not a small shell — no `PATH` search, no expansion, no interpretation —
and it is a separate binary from `dinix-init`, which is in every image and
must never be able to run anything. This one reaches only the closures that
name it.

## Licensing

services-flake is MIT and devenv is Apache-2.0. A ported module keeps a comment
at the top naming the file it came from, and its licence.
