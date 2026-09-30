# postgres, through the modular-service port in services/postgres.nix.
#
# `initdb` runs once as a sub-service of the instance, guarded by dinix-unless
# against a data directory that already holds a cluster. The sub-service is a
# separate dinit service, `<name>-init`, and the module wires the dependency.
#
# postgres refuses to run as root, so a privileged runtime would need `run-as`;
# the TUI wrapper runs `dinit --user` and this runs as you.
#
#   nix run --file ./dev.nix examples.services.postgres
#
# Then connect with the package in this closure:
#
#   psql -h "$DINIX_STATE_DIR/postgres/run" -U postgres -d postgres
{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, config, lib, ... }: {
      privileged = false;

      system.services.postgres = {
        imports = [
          (lib.modules.importApply ../../services/postgres.nix {
            inherit (pkgs) postgresql;
            dinix-unless = config.unlessPackage;
          })
        ];
        postgres = {
          port = 5432;
          # A setting reaches postgres as `-c name=value`, not through a file.
          settings.log_connections = true;
        };
      };
    })
  ];
}
