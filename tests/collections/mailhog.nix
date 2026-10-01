# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# mailhog is authored as a NixOS Modular Service. It keeps nothing on disk, so
# there is no writable path beyond /run. See services/mailhog.nix and
# PORTING.md.
{ pkgs, config, lib, ... }:
let
  mailhogService = lib.modules.importApply ../../services/mailhog.nix {
    inherit (pkgs) mailhog;
  };

  main = config.system.services.mailhog-main.mailhog;

  curl = "${pkgs.curl}/bin/curl";

  api = path: "${curl} -s http://127.0.0.1:${toString main.apiPort}${path}";
in
{
  system.services.mailhog-main = {
    imports = [ mailhogService ];
  };

  collection = {
    packages = [ pkgs.curl ];

    checks = [
      {
        name = "mailhog answers on its v2 API";
        command = api "/api/v2/messages";
        expect = "total";
      }
      {
        # The v1 endpoint answers with a bare array, so there is no field to
        # match. The status code is what says the endpoint is there.
        name = "and on its v1 API";
        command = "${curl} -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${toString main.apiPort}/api/v1/messages";
        expect = "200";
      }
    ];
  };
}
