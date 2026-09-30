# A NixOS Modular Service defined inline, with no file in services/.
#
# A module file is worth it when the service is shared or has options; the
# interface a service fills is the same either way. This fills the portable
# part — `process.argv` — and the dinix part, which a portable module reaches
# through `options ? dinit`. See modular.nix and PORTING.md.
#
#   nix run --file ./dev.nix examples.api.modular
{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:
let
  stateDir = (import ../../service-lib.nix).stateDir;
in
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      privileged = false;

      system.services.ticker = {
        process.argv = [
          (pkgs.writeShellScript "ticker.sh" ''
            while true; do
              echo "tick"
              ${pkgs.coreutils}/bin/sleep 1
            done
          '')
        ];

        # Where the service keeps what it writes, and who owns it, are
        # questions the portable layer leaves open. Under dinit they are the
        # `dinit` tree.
        dinit.dirs."${stateDir}/ticker".mode = "0755";

        dinit.service = {
          restart = true;
          restart-limit-count = 0;
          dinix.critical = false;
        };
      };
    })
  ];
}
