# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# nginx is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/nginx.nix and
# PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  nginxService = lib.modules.importApply ../../services/nginx.nix {
    inherit (pkgs) nginx mailcap;
  };

  main = config.system.services.nginx-main.nginx;

  # The page under test. A store path like any other, so the worker user —
  # nginx's compiled-in nobody — can read it without anything being done.
  site = pkgs.runCommand "dinix-nginx-site" { } ''
    mkdir $out
    echo '<h1>dinix serves</h1>' > $out/index.html
  '';
  curl = "${pkgs.curl}/bin/curl";
in
{
  system.services.nginx-main = {
    imports = [ nginxService ];

    # A server block of the collection's own, on its own port: the generated
    # server block is first on the module's port, so a second block on that
    # port would never see a request.
    nginx.httpConfig = ''
      server {
        listen 8081;
        root ${site};
        index index.html;
      }
    '';

    # nginx as root resolves its compiled-in worker group `nogroup` and dies
    # with `getgrnam("nogroup") failed`, and dinix writes no such group.
    # dinit's run-as changes user before exec, so the master never sees root
    # at all — and running unprivileged skips the lookup outright. nobody is
    # in the user database dinix writes, and dinit resolves the name against
    # the passwd and group files the container mounts a file at a time.
    # run-as is a dinit setting, so it goes on the service's dinit tree rather
    # than among the nginx options. Only a privileged dinit sets it: an
    # unprivileged one cannot change user at all.
    dinit.service.run-as = lib.mkIf config.privileged "nobody";

    # The master writes its pid file, its early error log and its temp
    # directory here, so the data directory belongs to the account the service
    # runs as. 65534 twice is users.nobody in users.nix, which is only a
    # default: a configuration with its own nobody must say so here as well.
    # An unprivileged dinix-init cannot chown, but it stats first and skips
    # what already matches, so this holds in every mode.
    dinit.dirs.${main.dataDir} = {
      uid = 65534;
      gid = 65534;
    };
  };

  collection = {
    # The writable paths a read-only deployment mounts: dinix-init makes the
    # data directory from `dirs`, and the temp paths go inside it.
    writable = [ main.dataDir ];

    packages = [ pkgs.curl ];

    checks = [
      {
        name = "nginx serves the static page";
        command = "${curl} -s http://127.0.0.1:8081/";
        expect = "dinix serves";
      }
      {
        name = "the generated server block answers on the module's port";
        command = "${curl} -s http://127.0.0.1:8080/";
        expect = "Welcome to nginx";
      }
    ];
  };
}
