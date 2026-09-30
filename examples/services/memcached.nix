# memcached, through the modular-service port in services/memcached.nix.
#
# The simplest port: no data directory, because memcached keeps nothing on
# disk, and no wrapper, because the options are already arguments.
#
# memcached refuses to run as root and normally drops to `nobody` with `-u`.
# This runs as you through `dinit --user`, where that flag is unnecessary and a
# `setuid` it cannot perform would only fail.
#
#   nix run --file ./dev.nix examples.services.memcached
{ pkgs ? import <nixpkgs> { } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, lib, ... }: {
      privileged = false;

      system.services.memcached = {
        imports = [
          (lib.modules.importApply ../../services/memcached.nix { inherit (pkgs) memcached; })
        ];
        memcached = {
          port = 11211;
          startArgs = [ "--memory-limit=64" ];
        };
      };
    })
  ];
}
