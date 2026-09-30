# A small dinix configuration for the TUI quick start. Two services: one that
# prints a line so the log pane has something to show, and one internal that
# never runs a process.
#
#   nix run --file ./dev.nix examples.hello
#   nix run --file ./examples/hello.nix config.userWrapper -- --user
{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:
import ../. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      services.hello = {
        type = "process";
        command = pkgs.writeShellScript "hello.sh" ''
          echo "hello from the dinix TUI example"
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        dinix.log = "buffer";
        dinix.critical = false;
      };

      services.world.type = "internal";
    })
  ];
}
