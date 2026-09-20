# Agent notes for dinix

## Porting a service

Read [PORTING.md](PORTING.md) first. `services/redis.nix` and
`tests/collections/redis.nix` are the worked pair; `services/postgres.nix` is
the hard one (sub-service, run-once init, `run-as`).

Two source libraries, both worth reading for the same service:
`~/Code/services-flake/nix/services/<name>.nix` (MIT) and
`~/Code/devenv/src/modules/services/<name>.nix` (Apache-2.0).

- Every service dinix authors is a NixOS Modular Service in `services/`. No
  `pkgs` argument: dependencies arrive through `lib.modules.importApply`.
- `config = lib.mkMerge [ ... ]`, not `//`, when both halves set the service's
  own option. `//` is shallow and drops one silently.
- Render before running a test: `nix build --file ./dev.nix collections.<name>.root`
  builds the image, but the rendered service description is what shows a
  quoting or merge bug.
- A port passes in **all four modes**:

      nix build --file ./dev.nix collections.<name>.{root,user,vm-root,vm-user}

  `nix build --file ./dev.nix checks` is every collection and both container
  tests, which is what CI builds.
- State paths belong on the command line, never inside a file the program
  reads. That rule is what makes one store path run rootful, rootless and
  uncontained. No flag for it? `env` carries a variable, a `PATH` or a
  working directory (`--chdir`) and still execs.
- A service's own configuration cannot decide which attributes it defines.
  `lib.optionalAttrs cfg.foo { dinit = ...; }` recurses; `lib.mkIf` does not.
- Check the package first: `meta.license.free`, and whether it is marked
  insecure. `dev.nix` takes a plain `import <nixpkgs> { }`.

## dinit service settings

The full set of service-description settings — names, and the assignment
forms (`:`, `=`, `+=`) each accepts — is a table in dinit's source, not
anything this repository mirrors:

    nix build --file /etc/nixpkgs dinit.src --no-link --print-out-paths

- `src/settings.cc` — `all_settings[]`, the complete setting table with its
  assignment forms.
- `src/includes/dinit-settings.h` — the setting-name constants; the comment
  there calls them the authoritative definitions.
- `src/includes/load-service.h` — the value parser: word splitting, quoting,
  `$` substitution, and the values `options:` accepts.
- `doc/manpages/dinit-service.5.m4` — the man page source, same tree. The
  built package installs it at `share/man/man5/dinit-service.5.gz`.

dinix renders `services.<name>` attribute names straight through, so a
setting name or assignment form absent from that table fails dinit-check at
build time. `options.nix` declares the settings that need list handling or a
dinix sub-option (`depends-on`, `dinix.*`, …); the rest is the freeform type.
