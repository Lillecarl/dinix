# Automatic restart. dinit's own default is to restart a failed process; the
# settings below make the loop visible and keep it going.
#
#   restart              yes / no / on-failure.
#   restart-delay        seconds between restarts.
#   restart-limit-count  0 to lift the limit, which is three restarts in ten
#                        seconds by default. Without it dinit gives up and the
#                        service stays stopped.
#
#   nix run --file ./dev.nix examples.features.restart
{ pkgs ? import <nixpkgs> { } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      services.flaky = {
        type = "process";
        command = pkgs.writeShellScript "flaky.sh" ''
          echo "flaky: up at $(${pkgs.coreutils}/bin/date +%H:%M:%S), exiting in 2s"
          ${pkgs.coreutils}/bin/sleep 2
          echo "flaky: exiting with 1"
          exit 1
        '';
        restart = true;
        restart-delay = 1;
        restart-limit-count = 0;
        dinix.log = "buffer";
        dinix.critical = false;
      };
    })
  ];
}
