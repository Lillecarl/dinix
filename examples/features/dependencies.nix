# The three dependency settings dinit-service(5) offers, passed straight
# through. The TUI shows the order in the state column as each one comes up.
#
#   depends-on   a hard dependency: start it first, stop after it, and stop
#                when it stops.
#   waits-for    start after it, but a failure does not propagate.
#   after        order only, no start or stop coupling.
#
#   nix run --file ./dev.nix examples.features.dependencies
{ pkgs ? import <nixpkgs> { } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      services.database = {
        type = "process";
        command = pkgs.writeShellScript "database.sh" ''
          echo "database: accepting connections"
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        dinix.log = "buffer";
        dinix.critical = false;
      };

      # depends-on does not only order: if the database stops, this stops too.
      services.migrate = {
        type = "scripted";
        command = pkgs.writeShellScript "migrate.sh" ''
          echo "migrate: schema is current"
        '';
        depends-on = [ "database" ];
        dinix.log = "buffer";
        dinix.critical = false;
      };

      # waits-for orders without coupling: the worker starts after migrate, but
      # migrate failing does not stop the worker.
      services.worker = {
        type = "process";
        command = pkgs.writeShellScript "worker.sh" ''
          echo "worker: polling for work"
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        waits-for = [ "migrate" ];
        dinix.log = "buffer";
        dinix.critical = false;
      };
    })
  ];
}
