# A container image for redis.
#
# The same configuration runs as PID 1 of a container: the entrypoint is
# `config.containerWrapper`, dinit reads the services from the store, and the
# image needs no shell and no writable root. What is different from the TUI
# example is `dinix.critical = true` — in a container redis is why the
# container exists, so when it stops dinit exits and the runtime restarts the
# whole thing.
#
# The image is built by dev.nix, which has nix2container:
#
#   nix run --file ./dev.nix containers.redis.copyToPodman
#   podman run --rm -it -p 6379:6379 dinix-example-redis:latest
{ pkgs ? import <nixpkgs> { } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, lib, ... }: {
      system.services.redis = {
        imports = [
          (lib.modules.importApply ../../services/redis.nix { inherit (pkgs) redis; })
        ];
        redis.port = 6379;
        dinit.service.dinix.critical = true;
      };
    })
  ];
}
