# Agent notes for dinix

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
