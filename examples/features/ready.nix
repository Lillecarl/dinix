# Readiness notification. A process service is normally STARTED as soon as it
# has begun execution; with `ready-notification` it stays STARTING until it
# writes to the pipe dinit hands it. A dependent then waits for the real thing
# rather than for the process to have been spawned.
#
# `pipefd:3` makes dinit give the service fd 3, the write end of a pipe. The
# format is the one the S6 supervision suite uses. `pipevar:NAME` does the same
# through an environment variable holding the fd number.
#
#   nix run --file ./dev.nix examples.features.ready
{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      services.warms-up = {
        type = "process";
        command = pkgs.writeShellScript "warms-up.sh" ''
          echo "warms-up: warming up for one second"
          ${pkgs.coreutils}/bin/sleep 1
          echo "warms-up: signalling ready"
          echo ready >&3
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        ready-notification = "pipefd:3";
        dinix.log = "buffer";
        dinix.critical = false;
      };

      # depends-on waits for STARTED, so this prints only after the line above.
      services.dependent = {
        type = "process";
        command = pkgs.writeShellScript "dependent.sh" ''
          echo "dependent: the service it needs is now STARTED"
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        depends-on = [ "warms-up" ];
        dinix.log = "buffer";
        dinix.critical = false;
      };
    })
  ];
}
