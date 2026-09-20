# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# Caddy is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/caddy.nix and
# PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  caddyService = lib.modules.importApply ../../services/caddy.nix {
    inherit (pkgs) caddy coreutils;
  };

  main = config.system.services.caddy-main.caddy;
  alt = config.system.services.caddy-alt.caddy;

  curl = "${pkgs.curl}/bin/curl";

  # A document root in the store, which is where a read-only one belongs: it
  # is part of the image and nothing writes to it.
  site = pkgs.runCommand "dinix-caddy-site" { } ''
    mkdir --parents $out
    echo dinix-from-a-file > $out/index.html
  '';

  # Every site is http://, so Caddy asks for no certificate. `admin off`
  # because its admin endpoint binds 127.0.0.1:2019 by default and two
  # instances would fight over it.
  serve = port: body: ''
    {
      admin off
      auto_https off
    }

    http://127.0.0.1:${toString port} {
      ${body}
    }
  '';
in
{
  system.services.caddy-main = {
    imports = [ caddyService ];
    caddy.caddyfile = serve 8080 ''
      root * ${site}
      file_server
    '';
  };

  # A second instance on its own port, answering from its configuration
  # rather than from a file. Two of them is what catches instances sharing
  # state — here the XDG directories Caddy writes to.
  system.services.caddy-alt = {
    imports = [ caddyService ];
    caddy.caddyfile = serve 8081 ''
      respond "dinix-from-alt"
    '';
  };

  collection = {
    packages = [ pkgs.curl ];

    writable = [
      main.dataDir
      alt.dataDir
    ];

    checks = [
      {
        name = "caddy serves a file from the store";
        command = "${curl} --silent --fail http://127.0.0.1:8080/";
        expect = "dinix-from-a-file";
      }
      {
        name = "and the second instance answers for itself";
        command = "${curl} --silent --fail http://127.0.0.1:8081/";
        expect = "dinix-from-alt";
      }
    ];
  };
}
