# The three log destinations dinix exposes through `dinix.log`.
#
#   console  the service shares dinit's own console, so its output joins the
#            stream a container runtime collects. The default for a process.
#   buffer   kept in memory, readable with `dinitctl catlog`. Press `l` to
#            read one and `f` to follow it. No rotation is needed: the buffer
#            is a ring.
#   file     appended to `logfile`. dinit does not rotate it, so whatever owns
#            the volume has to.
#
#   nix run --file ./dev.nix examples.features.logs
{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:
let
  # dinit expands this when it loads the service, so the same store
  # configuration writes wherever DINIX_STATE_DIR points. See service-lib.nix.
  stateDir = (import ../../service-lib.nix).stateDir;

  chatty =
    name:
    pkgs.writeShellScript "${name}.sh" ''
      i=0
      while true; do
        i=$((i + 1))
        echo "${name}: line $i"
        ${pkgs.coreutils}/bin/sleep 1
      done
    '';
in
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      # A file destination needs a directory that exists when the service
      # starts. dinix-init makes this before anything runs.
      dirs."${stateDir}/logs".mode = "0755";

      services.on-console = {
        type = "process";
        command = chatty "on-console";
        dinix.log = "console";
        dinix.critical = false;
      };

      services.in-buffer = {
        type = "process";
        command = chatty "in-buffer";
        dinix.log = "buffer";
        dinix.critical = false;
      };

      services.to-file = {
        type = "process";
        command = chatty "to-file";
        logfile = "${stateDir}/logs/to-file.log";
        dinix.log = "file";
        dinix.critical = false;
      };
    })
  ];
}
