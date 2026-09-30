# redis, through the modular-service port in services/redis.nix.
#
# A NixOS Modular Service says what to run without saying who runs it, so the
# same module works under dinit, under systemd and under finit. dinix
# instantiates one under `system.services`, one attribute per instance; the
# module is imported with its package through `importApply` so it is not tied
# to one nixpkgs. See PORTING.md.
#
# `privileged = false` is what a TUI-driven runtime needs: the wrapper runs
# `dinit --user`, which cannot change user, so a service must not ask it to.
#
#   nix run --file ./dev.nix examples.services.redis
#   nix run --file ./examples/services/redis.nix config.userWrapper -- --user
{ pkgs ? import <nixpkgs> { } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, lib, ... }: {
      privileged = false;

      system.services.redis = {
        imports = [
          (lib.modules.importApply ../../services/redis.nix { inherit (pkgs) redis; })
        ];
        redis = {
          port = 6379;
          # A second way in, and the one a neighbouring service in the same
          # instance would use. The module puts it under the state directory.
          unixSocket = "redis.sock";
        };
      };
    })
  ];
}
