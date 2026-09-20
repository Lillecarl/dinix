# nginx, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/nginx/default.nix, which is
# MIT and itself based on devenv's Apache-2.0 module. See services/redis.nix for
# the shape and PORTING.md for what changes on the way across.
{ nginx, mailcap }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.nginx;
in
{
  _class = "service";

  options.nginx = {
    package = mkOption {
      type = types.package;
      default = nginx;
      defaultText = lib.literalMD "the nginx given to this module";
      description = "The nginx package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        The prefix nginx runs under, and so where it writes.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir` for why a manager without that
        option needs this set.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = ''
        The TCP port the generated server block accepts connections on.
      '';
    };

    root = mkOption {
      type = types.str;
      default = "${cfg.package}/html";
      defaultText = lib.literalMD "the package's own placeholder page";
      description = ''
        The document root the generated server block serves.

        The default is the package's own placeholder page, which is what nginx
        serves out of the box. Point it at your own content, or leave it and
        add a `server` block of your own through {option}`nginx.httpConfig`.
      '';
    };

    defaultMimeTypes = mkOption {
      type = types.path;
      default = "${mailcap}/etc/nginx/mime.types";
      defaultText = lib.literalMD "the map from the mailcap given to this module";
      description = ''
        The MIME types map. nginx's own list is very incomplete, so the default
        takes the one from the mailcap package, as most other Linux
        distributions do.
      '';
    };

    httpConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Appended inside the `http` block, after the generated server block. A
        `server` block added here listens on its own port: the generated one is
        first on {option}`nginx.port`, so it is the default server.
      '';
    };

    eventsConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Appended inside the `events` block.
      '';
    };
  };

  config = {
    # configData is how a modular service carries a file it needs, so the
    # manager decides where the file lands and the module reads the place back
    # out of `.path`. See the `modular` collection.
    #
    # Every path in here is relative, and resolves against the prefix `-p`
    # names on the command line. It has to be: nginx reads this file itself and
    # knows nothing of the substitution a service manager does, so an absolute
    # dataDir would arrive as a literal ${DINIX_STATE_DIR...}. The prefix is on
    # the command line, which every manager substitutes. See PORTING.md.
    configData."nginx.conf".text = ''
      pid nginx/nginx.pid;
      error_log stderr;
      daemon off;

      events {
        ${cfg.eventsConfig}
      }

      http {
        access_log off;
        # The one writable place a container gives nginx. nginx makes the
        # `nginx` directory itself at startup, so it needs no `dirs` entry of
        # its own.
        client_body_temp_path nginx/;
        proxy_temp_path nginx/;
        fastcgi_temp_path nginx/;
        scgi_temp_path nginx/;
        uwsgi_temp_path nginx/;

        include ${cfg.defaultMimeTypes};

        server {
          listen ${toString cfg.port};
          # Named rather than inherited. nginx resolves a relative `root`
          # against the prefix, and the prefix is the data directory here, so
          # the default `html` would look for pages among the state and answer
          # 404. This is content, so it is a store path and needs no
          # substitution.
          root ${cfg.root};
        }
        ${cfg.httpConfig}
      }
    '';

    # No wrapper and no shell. services-flake runs `nginx -p "$(pwd)"`; this
    # names the prefix outright, which is also what lets every path in the
    # configuration be relative. `daemon off` lives in the configuration only:
    # passing it on the command line as well with `-g "daemon off;"` makes
    # nginx die with `"daemon" directive is duplicate`. Measured against nginx
    # 1.30.4.
    #
    # `-e` names a file under the prefix rather than /dev/stderr: the errors
    # nginx writes before the configuration's own `error_log` takes effect
    # never reached the collected stream addressed as /dev/stderr. Measured
    # against nginx 1.30.4 in a dinix container.
    process.argv = [
      (lib.getExe' cfg.package "nginx")
      "-p"
      cfg.dataDir
      "-c"
      config.configData."nginx.conf".path
      "-e"
      "nginx-error.log"
    ];
  }
  // lib.optionalAttrs (options ? dinit) {
    nginx.dataDir = lib.mkDefault config.dinit.stateDir;
    # The master writes the pid file and the early error log here, and makes
    # the temp directory beside them. Whoever the service runs as must own this
    # directory: as root the compiled-in worker group `nogroup` fails to
    # resolve, so a container runs it as nobody and owns the directory to that
    # account. See the nginx collection.
    dinit.dirs.${cfg.dataDir}.mode = "0700";
    # services-flake asks process-compose for restart = "on_failure" with at
    # most 5 restarts. See services/redis.nix for what this means.
    dinit.service.dinix.critical = lib.mkDefault false;
  };

  meta.maintainers = [ ];
}
