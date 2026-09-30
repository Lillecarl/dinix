# dinix examples

Every file under `examples/` is a complete dinix configuration. It evaluates on
its own, and `dev.nix` wraps each one in a runner that starts dinit and opens
the TUI on it.

```sh
nix run --file ./dev.nix examples.services.redis
```

The runner makes a temporary runtime directory and points `DINIX_STATE_DIR` at
a writable one, so a service that keeps state needs nothing set up.

A file runs without the TUI as well. Then you choose both directories:

```sh
DINIX_STATE_DIR=$PWD/state nix run --file ./examples/services/redis.nix config.userWrapper -- --user
```

## What each one shows

| Example | Shows |
| --- | --- |
| `examples.hello` | the quick start: two services, one process and one internal |
| `examples.features.dependencies` | `depends-on`, `waits-for` and `after` |
| `examples.features.restart` | automatic restart, with the limit lifted |
| `examples.features.logs` | the `console`, `buffer` and `file` log destinations |
| `examples.features.ready` | `ready-notification`, so a dependent waits for STARTED |
| `examples.features.critical` | `dinix.critical`, and what a service stopping means |
| `examples.services.redis` | redis, from the modular-service port |
| `examples.services.postgres` | postgres, with `initdb` as a run-once sub-service |
| `examples.services.nginx` | nginx, serving a store path |
| `examples.services.memcached` | memcached, the simplest port |
| `examples.containers.redis` | a container image, built by `dev.nix` |
| `examples.containers.nginx` | a container image for nginx |
| `examples.api.usage` | what `import ./dinix` returns |
| `examples.api.modular` | a modular service defined inline |

## Containers

`dev.nix` builds the container images with nix2container and loads them with
podman:

```sh
nix run --file ./dev.nix containers.redis.copyToPodman
podman run --rm -it -p 6379:6379 dinix-example-redis:latest
```

The entrypoint is `config.containerWrapper`: dinit as PID 1, reading its
services from the store, in an image with no shell and no writable root.

## The API

An example is an `import ../.. { modules = [ ... ]; }`. The result carries the
evaluated configuration, so you can build any piece of it:

```sh
nix build --file ./examples/api/usage.nix config.configDir
nix build --file ./examples/api/usage.nix config.containerWrapper
```

`examples/api/usage.nix` lists the attributes and what each one is for.

## TUI keys

| Key | Action |
| --- | --- |
| `s` | start the selected service |
| `x` | stop the selected service |
| `r` | restart the selected service |
| `R` | reload the selected service's description |
| `l` | print the selected service's log |
| `f` | follow the selected service's log (poll the buffer) |
| `n` | nix reload: rebuild and adopt the new configuration |
| `A` | reload all: rebuild, reload, and restart every running service |
| `f5` | refresh the service list |
| `q` | quit |

## Editing and nix reload

`n` runs a rebuild command, points the runtime at its output, and reloads every
service. The runner wires that command to `nix build --file <this example>
config.configDir`, so an edit to the file is picked up on `n`. The new
description applies at the next start: press `r` to restart one service, or `A`
to rebuild and restart everything at once.

The rebuild's own output streams into the log pane, prefixed `nix|`, so a slow
evaluation shows progress instead of a silent wait.

For a project of your own, set `DINIX_TUI_NIX_COMMAND` to a command that
builds your configuration and prints its config directory. The wrapper's
`dinit` searches `<DINIX_RUNTIME_DIR>/current` before the store, which is the
pointer `n` repoints.
