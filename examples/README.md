# dinix TUI example

A quick look at the TUI. One command starts dinit from a small configuration
and opens the interface on it.

```sh
nix run --file ./dev.nix example
```

`examples/hello.nix` defines two services: `hello` is a process that prints a
line and sleeps, and `world` is internal. Both appear when the TUI connects.

## Keys

| Key | Action |
| --- | --- |
| `s` | start the selected service |
| `x` | stop the selected service |
| `r` | restart the selected service |
| `R` | reload the selected service's description |
| `l` | print the selected service's log |
| `f` | follow the selected service's log (poll the buffer) |
| `n` | nix reload: rebuild and adopt the new configuration |
| `f5` | refresh the service list |
| `q` | quit |

## Nix reload

`n` runs a rebuild command, points the runtime at its output, and reloads every
service. The new description applies at the next start, so press `r` to restart
one and see the change.

The example wires `n` to a fake rebuild that writes a new `hello` description.
Press `n` then `r` and the log shows a different line. Press `n` again for a
third.

For a real project, set `DINIX_TUI_NIX_COMMAND` to a command that builds your
configuration and prints its config directory. The wrapper's `dinit` searches
`<DINIX_RUNTIME_DIR>/current` before the store, which is the pointer `n`
repoints.
