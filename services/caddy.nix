# Caddy, as a NixOS Modular Service.
#
# Options ported from devenv's src/modules/services/caddy.nix, which is
# Apache-2.0. See services/redis.nix for the shape and PORTING.md for what
# changes on the way across.
{ caddy, coreutils }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.caddy;
in
{
  _class = "service";

  options.caddy = {
    package = mkOption {
      type = types.package;
      default = caddy;
      defaultText = lib.literalMD "the caddy given to this module";
      description = "The caddy package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where Caddy keeps its certificates and its own state.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    caddyfile = mkOption {
      type = types.lines;
      example = ''
        {
          auto_https off
        }

        http://127.0.0.1:8080 {
          root * /srv/http
          file_server
        }
      '';
      description = ''
        The configuration, in the format {option}`caddy.adapter` names.

        Two things a container asks of it. Turn `auto_https` off, or name every
        site with an `http://` scheme: Caddy otherwise tries to get a
        certificate over ACME, which needs a network and a resolvable name.
        And a path in here — a document root, a log file — is fixed when this
        is generated, so it cannot be under the state directory. See
        PORTING.md.
      '';
    };

    adapter = mkOption {
      type = types.str;
      default = "caddyfile";
      example = "nginx";
      description = ''
        Which config adapter reads {option}`caddy.caddyfile`. See
        <https://caddyserver.com/docs/config-adapters>.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--resume" ];
      description = ''
        Arguments appended to `caddy run`, one argument per element.
      '';
    };
  };

  config = lib.mkMerge [
    {
      configData."Caddyfile".text = cfg.caddyfile;

      # Caddy takes its state directory from XDG_DATA_HOME and XDG_CONFIG_HOME
      # and from no argument, so `env` carries them — the same way it carries
      # mysql's PATH, and for the same reason: a service manager substitutes a
      # command line. Without them Caddy says "unable to determine directory
      # for user configuration; falling back to current directory", which in a
      # container is wherever dinit happens to be.
      process.argv = [
        (lib.getExe' coreutils "env")
        "XDG_DATA_HOME=${cfg.dataDir}/data"
        "XDG_CONFIG_HOME=${cfg.dataDir}/config"
        (lib.getExe cfg.package)
        "run"
        "--config"
        config.configData."Caddyfile".path
        "--adapter"
        cfg.adapter
      ]
      ++ cfg.extraArgs;
    }

    (lib.optionalAttrs (options ? dinit) {
      caddy.dataDir = lib.mkDefault config.dinit.stateDir;
      dinit.dirs.${cfg.dataDir}.mode = "0700";
      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
