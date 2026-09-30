# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# garage is authored as a NixOS Modular Service. It needs a shell, so this is
# one of the rare ports whose image carries one. See services/garage.nix and
# PORTING.md.
{ pkgs, config, lib, ... }:
let
  garageService = lib.modules.importApply ../../services/garage.nix {
    garage = pkgs.garage_2;
    inherit (pkgs) bash coreutils;
  };

  main = config.system.services.garage-main.garage;

  curl = "${pkgs.curl}/bin/curl";
  garage = "${pkgs.garage_2}/bin/garage";
in
{
  system.services.garage-main = {
    imports = [ garageService ];
    garage.buckets = [ "dinix" ];
  };

  collection = {
    writable = [ main.dataDir ];

    packages = [
      pkgs.curl
      pkgs.garage_2
    ];

    checks = [
      {
        # "healthy" rather than "unavailable": garage reports the latter until
        # the layout has been applied, so this also proves the init service ran.
        name = "garage reports itself healthy once the layout is applied";
        command = "${curl} -s -H 'Authorization: Bearer ${main.adminToken}' http://127.0.0.1:${toString main.adminPort}/v1/health";
        expect = "healthy";
      }
      {
        name = "the declared bucket exists";
        command = "${garage} -c ${main.dataDir}/garage.toml bucket info dinix";
        expect = "dinix";
      }
    ];
  };
}
