# A collection that runs a NixOS Modular Service, unmodified, under dinit.
#
# The module is nixpkgs' own — the one its modular-service test uses — imported
# from the pinned tree rather than copied. That is the point: if dinix's
# implementation of the interface drifts, this stops working.
#
# See PORTING.md and the `system.services` option.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  curl = "${pkgs.curl}/bin/curl";
in
{
  system.services.web = {
    imports = [ (pkgs.path + "/nixos/tests/modular-service-etc/python-http-server.nix") ];

    python-http-server = {
      package = pkgs.python3;
      port = 8080;
    };

    # configData is the portable way a service carries content, and `source`
    # may be a directory as well as a file — which is what this module wants,
    # since it serves one. dinix decides where it lands, inside configDir, and
    # the module reads the location back out of `configData.webroot.path` for
    # its own --directory argument.
    #
    # Left at the module's default of serving exactly this path: it enables
    # the entry only when `directory` is that path, so pointing `directory`
    # elsewhere silently turns the content off.
    configData."webroot".source = pkgs.runCommand "dinix-modular-site" { } ''
      mkdir $out
      echo '<h1>dinix runs a modular service</h1>' > $out/index.html
    '';

    # The dinit option tree, which is what a portable module targets with
    # lib.optionalAttrs (options ? dinit). Here the collection uses it to say
    # the service is why the container exists.
    dinit.service.dinix.critical = true;
  };

  collection = {
    checks = [
      {
        name = "an upstream modular service answers under dinit";
        command = "${curl} -s http://127.0.0.1:8080/index.html";
        expect = "dinix runs a modular service";
      }
      {
        # The file came from configData rather than from a store path the
        # module named itself, which is the part of the interface dinix
        # implements rather than inherits.
        name = "and serves the file configData placed";
        command = "${curl} -s -o /dev/null -w %{http_code} http://127.0.0.1:8080/index.html";
        expect = "200";
      }
    ];

    packages = [ pkgs.curl ];
  };
}
