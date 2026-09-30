# A dinix instance for the integration check. `marker` is the line the hello
# service prints, so two instances differ in exactly that one line. The check
# swaps one for the other to exercise reload against a real dinit.
{
  pkgs ? import <nixpkgs> { },
  marker ? "hello-from-hello",
}:
import ../.. {
  inherit pkgs;
  modules = [
    (
      { pkgs, ... }:
      {
        services.hello = {
          type = "process";
          command = pkgs.writeShellScript "hello.sh" ''
            echo ${marker}
            exec ${pkgs.coreutils}/bin/sleep 3600
          '';
          dinix.log = "buffer";
        };

        services.world.type = "internal";
      }
    )
  ];
}
