# A small dinix configuration for the TUI example. Two services: one that
# prints a line so the log pane has something to show, and one internal that
# never runs a process.
{ pkgs, ... }:
{
  services.hello = {
    type = "process";
    command = pkgs.writeShellScript "hello.sh" ''
      echo "hello from the dinix TUI example"
      exec ${pkgs.coreutils}/bin/sleep 3600
    '';
    dinix.log = "buffer";
  };

  services.world.type = "internal";
}
