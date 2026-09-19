# Ported from services-flake, nix/services/nginx/default.nix, which is
# Apache-2.0 and itself based on devenv's module. The options are theirs,
# option for option. See PORTING.md for what changes on the way across.
let
  inherit (import ./service-lib.nix) multiService;
in
multiService "nginx" (
  {
    config,
    pkgs,
    lib,
    ...
  }:
  let
    inherit (lib) mkOption types;

    configFile = pkgs.writeText "nginx-${config.serviceName}.conf" ''
      pid ${config.dataDir}/nginx/nginx.pid;
      error_log stderr;
      daemon off;

      events {
        ${config.eventsConfig}
      }

      http {
        access_log off;
        # The one writable place a container gives nginx. nginx makes the
        # `nginx` directory itself at startup, so it needs no `dirs` entry of
        # its own.
        client_body_temp_path ${config.dataDir}/nginx/;
        proxy_temp_path ${config.dataDir}/nginx/;
        fastcgi_temp_path ${config.dataDir}/nginx/;
        scgi_temp_path ${config.dataDir}/nginx/;
        uwsgi_temp_path ${config.dataDir}/nginx/;

        include ${config.defaultMimeTypes};

        server {
          listen ${toString config.port};
        }
        ${config.httpConfig}
      }
    '';
  in
  {
    options = {
      package = mkOption {
        type = types.package;
        default = pkgs.nginx;
        defaultText = lib.literalExpression "pkgs.nginx";
        description = "The nginx package to use.";
      };

      port = mkOption {
        type = types.port;
        default = 8080;
        description = ''
          The TCP port the generated server block accepts connections on.
        '';
      };

      defaultMimeTypes = mkOption {
        type = types.path;
        default = "${pkgs.mailcap}/etc/nginx/mime.types";
        defaultText = lib.literalExpression "\${pkgs.mailcap}/etc/nginx/mime.types";
        description = ''
          The MIME types map. nginx's own list is very incomplete, so the
          default takes the one from the mailcap package, as most other Linux
          distributions do.
        '';
      };

      httpConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Appended inside the `http` block, after the generated server block.
          A `server` block added here listens on its own port: the generated
          one is first on {option}`port`, so it is the default server.
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
      outputs.dirs.${config.dataDir} = {
        # The master writes the pid file and the early error log here, and
        # makes the temp directory beside them. Whoever the service runs as
        # must own this directory: as root the compiled-in worker group
        # `nogroup` fails to resolve, so a container runs it as nobody and
        # owns the directory to that account. See the nginx collection.
        mode = "0700";
      };

      outputs.services.${config.serviceName} = {
        type = "process";
        # No wrapper and no shell. services-flake runs `nginx -p "$(pwd)"` and
        # symlinks the configuration into the data directory; every path this
        # configuration names is absolute, so the prefix is the compiled-in
        # one and `-c` takes the store path as it is. `daemon off` lives in
        # the configuration only: passing it on the command line as well with
        # `-g "daemon off;"` makes nginx die with `"daemon" directive is
        # duplicate`. Measured against nginx 1.30.4.
        #
        # `-e` names a file on the data directory rather than /dev/stderr:
        # the errors nginx writes before the configuration's own `error_log`
        # takes effect never reached the collected stream addressed as
        # /dev/stderr. Measured against nginx 1.30.4 in this container.
        command = "${lib.getExe' config.package "nginx"} -c ${configFile} -e ${config.dataDir}/nginx-error.log";
        # services-flake asks process-compose for restart = "on_failure" with
        # at most 5 restarts. See redis.nix for what dinix.critical = false
        # means.
        dinix.critical = lib.mkDefault false;
      };
    };
  }
)
