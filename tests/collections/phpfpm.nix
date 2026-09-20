# A collection: the dinix configuration under test, plus what to ask the
# running container. dev.nix turns this into an image, a guest and a test.
#
# Two pools out of services-flake's own phpfpm_test.nix: one answering on a
# socket, one on TCP. See PORTING.md.
{ pkgs, config, lib, ... }:
let
  fcgi = "${pkgs.fcgi}/bin/cgi-fcgi";
  env = "${pkgs.coreutils}/bin/env";

  # services-flake probes with `env -i` because php-fpm ignores a request
  # whose FastCGI parameters — which is what cgi-fcgi makes of its
  # environment — grow too large. Absolute paths throughout: the image has
  # no PATH. See https://github.com/php/php-src/issues/16042.
  probe = address: "${env} -i ${fcgi} -bind -connect ${address}";
in
{
  phpfpm.main = {
    enable = true;
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

  phpfpm.alt = {
    enable = true;
    listen = 9000;
    extraConfig = {
      "pm" = "ondemand";
      "pm.max_children" = 1;
    };
  };

  # php-fpm runs as whoever starts it, and refuses no account, so no output
  # needs run-as except the rootContainer one: there dinit itself runs as
  # root, and the socket and the directory must belong to the account the
  # checks run as everywhere else. run-as is a dinit setting, so it goes on
  # the rendered service rather than on the pool, and an unprivileged dinit
  # cannot do it at all. nobody is in the user database dinix writes, and
  # dinit resolves the name against the passwd and group files the container
  # mounts a file at a time.
  services.phpfpm-main.run-as = lib.mkIf (config.mode == "rootContainer") "nobody";
  services.phpfpm-alt.run-as = lib.mkIf (config.mode == "rootContainer") "nobody";

  # The directory mode comes from the module; the owner comes from here, and
  # only the collection knows it: 65534 twice is users.nobody in users.nix.
  # An unprivileged dinix-init cannot chown, but it stats first and skips
  # what already matches, so this holds in every mode.
  dirs.${config.phpfpm.main.dataDir} = {
    uid = 65534;
    gid = 65534;
  };
  dirs.${config.phpfpm.alt.dataDir} = {
    uid = 65534;
    gid = 65534;
  };

  collection = {
    # The writable paths a read-only deployment mounts, one data directory
    # per pool.
    writable = [
      config.phpfpm.main.dataDir
      config.phpfpm.alt.dataDir
    ];

    packages = [
      pkgs.coreutils
      pkgs.fcgi
    ];

    checks =
      let
        # services-flake's rule, restated: a `listen` that names no absolute
        # path is a socket under the pool's data directory.
        socket = config.phpfpm.main.dataDir + "/" + config.phpfpm.main.listen;
      in
      [
        {
          # A bare connection carries no script, so the pool answers an
          # empty page. The X-Powered-By header is the proof: only the PHP
          # SAPI answering over FastCGI emits it, which is why the pool pins
          # expose_php above instead of trusting the default.
          name = "the socket pool answers over FastCGI";
          command = probe socket;
          expect = "X-Powered-By: PHP/";
        }
        {
          name = "the TCP pool answers over FastCGI";
          command = probe "127.0.0.1:${toString config.phpfpm.alt.listen}";
          expect = "X-Powered-By: PHP/";
        }
      ];
  };
}
