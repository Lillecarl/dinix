# What a service stopping means for the whole instance. `dinix.critical`
# writes the wiring on the boot service; the service itself is unchanged.
#
#   true   boot depends on it, so dinit must exit when it stops. A supervisor
#          outside dinit restarts the whole instance.
#   false  boot waits for it instead: it may die and come back forever without
#          dinit noticing.
#   null   nothing is wired; you write boot's dependencies yourself.
#
# Stop `backbone` with `x` and the TUI reports the socket closing: dinit has
# exited. `exporter` is the other side of it — it crashes every few seconds and
# the instance carries on.
#
#   nix run --file ./dev.nix examples.features.critical
{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      services.backbone = {
        type = "process";
        command = pkgs.writeShellScript "backbone.sh" ''
          echo "backbone: up"
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        dinix.log = "buffer";
        dinix.critical = true;
      };

      services.exporter = {
        type = "process";
        command = pkgs.writeShellScript "exporter.sh" ''
          echo "exporter: scraping, then crashing"
          ${pkgs.coreutils}/bin/sleep 5
          exit 1
        '';
        restart = true;
        restart-limit-count = 0;
        dinix.log = "buffer";
        dinix.critical = false;
      };
    })
  ];
}
