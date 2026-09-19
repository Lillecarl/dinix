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
    tmpfs = [ config.redis.main.dataDir ];
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
collections.<service>` runs it. Nothing else needs editing, and no Python is
written.

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

Four things change on the way across, and they are the whole of the work:

- **No shell.** services-flake wraps most services in a `writeShellApplication`
  to make a directory and export a variable. dinix makes directories with
  `dirs` before any service starts, and sets variables in `env-file`, so
  `command` is the program itself. A port that still needs a wrapper has found
  something worth saying out loud.
- **The data directory is a volume**, not a subdirectory of wherever the
  developer ran the command. Absolute paths throughout, and the test mounts it
  as a tmpfs so `dirs` is under test too.
- **No readiness probes.** process-compose polls a service until it answers;
  dinit does not. Where services-flake gates a dependent on
  `condition = "process_healthy"`, dinix has `depends-on`, which waits for the
  process to start and no more. A service that must not start before another
  is *ready* needs that readiness expressing some other way — usually the
  program's own flag, sometimes a `scripted` service that blocks.
- **Secrets and passwords are mounted**, never rendered into the store.
  Everything dinix generates is world-readable. See the host key note in
  README.md.

## Licensing

services-flake is Apache-2.0. A ported module keeps a comment at the top
naming the file it came from.
