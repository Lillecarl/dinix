# A tiny dinix configuration the integration check runs for real.
#
# Two services and no external daemon: `hello` prints and then outlives the
# test, `world` is internal and starts immediately. Nothing attaches either to
# `boot`, so the check starts them itself.
{
  pkgs,
  ...
}:
let
  helloScript = pkgs.writeShellScript "hello.sh" ''
    echo hello-from-hello
    exec ${pkgs.coreutils}/bin/sleep 3600
  '';
in
{
  services.hello = {
    type = "process";
    command = helloScript;
    dinix.log = "buffer";
  };

  services.world.type = "internal";
}
