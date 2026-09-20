# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# Two pools out of services-flake's own phpfpm_test.nix: one answering on a
# socket, one on TCP. php-fpm is authored as a NixOS Modular Service, so a pool
# is one `system.services` entry importing the module. See services/phpfpm.nix
# and PORTING.md.
#
# **No run-as here, deliberately.** php-fpm drops privilege itself: the master
# stays root and the pool's `user` and `group` directives set who the workers
# are. Taking root away before exec instead breaks the master, because it
# opens its error log by path — `/proc/self/fd/2`, which is dinit's own log —
# and a file dinit made as root refuses the account the service would become.
# Measured: `failed to open error_log (/proc/self/fd/2): Permission denied`,
# then exit 78, in vm-root mode.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  phpfpmService = lib.modules.importApply ../../services/phpfpm.nix {
    inherit (pkgs) php runCommand;
  };

  main = config.system.services.phpfpm-main.phpfpm;
  alt = config.system.services.phpfpm-alt.phpfpm;

  fcgi = "${pkgs.fcgi}/bin/cgi-fcgi";
  env = "${pkgs.coreutils}/bin/env";

  # services-flake probes with `env -i` because php-fpm ignores a request
  # whose FastCGI parameters — which is what cgi-fcgi makes of its
  # environment — grow too large. Absolute paths throughout: the image has
  # no PATH. See https://github.com/php/php-src/issues/16042.
  probe = address: "${env} -i ${fcgi} -bind -connect ${address}";

  # The directory mode comes from the module; the owner comes from here, and
  # only the collection knows it: 65534 twice is users.nobody in users.nix. An
  # unprivileged dinix-init cannot chown, but it stats first and skips what
  # already matches, so this holds in every mode.
  ownedByNobody = {
    uid = 65534;
    gid = 65534;
  };
in
{
  system.services.phpfpm-main = {
    imports = [ phpfpmService ];

    phpfpm = {
      listen = "phpfpm.sock";
      extraConfig = {
        "pm" = "ondemand";
        "pm.max_children" = 1;
      };
      phpOptions = ''
        date.timezone = "CET"
        expose_php = On
      '';
      phpEnv = {
        TMPDIR = "/tmp";
      };
      globalSettings = {
        "log_level" = "debug";
      };
    };

    dinit.dirs.${main.dataDir} = ownedByNobody;
  };

  system.services.phpfpm-alt = {
    imports = [ phpfpmService ];

    phpfpm = {
      listen = 9000;
      extraConfig = {
        "pm" = "ondemand";
        "pm.max_children" = 1;
      };
    };

    dinit.dirs.${alt.dataDir} = ownedByNobody;
  };

  collection = {
    # The writable paths a read-only deployment mounts, one data directory per
    # pool.
    writable = [
      main.dataDir
      alt.dataDir
    ];

    packages = [
      pkgs.coreutils
      pkgs.fcgi
    ];

    checks =
      let
        # services-flake's rule, restated: a `listen` that names no absolute
        # path is a socket under the pool's data directory.
        socket = main.dataDir + "/" + main.listen;
      in
      [
        {
          # A bare connection carries no script, so the pool answers an empty
          # page. The X-Powered-By header is the proof: only the PHP SAPI
          # answering over FastCGI emits it, which is why the pool pins
          # expose_php above instead of trusting the default.
          name = "the socket pool answers over FastCGI";
          command = probe socket;
          expect = "X-Powered-By: PHP/";
        }
        {
          name = "the TCP pool answers over FastCGI";
          command = probe "127.0.0.1:${toString alt.listen}";
          expect = "X-Powered-By: PHP/";
        }
      ];
  };
}
