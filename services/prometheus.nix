# Prometheus, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/prometheus.nix, which is
# MIT. See services/redis.nix for the shape and PORTING.md for what changes on
# the way across.
{ prometheus }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.prometheus;
in
{
  _class = "service";

  options.prometheus = {
    package = mkOption {
      type = types.package;
      default = prometheus;
      defaultText = lib.literalMD "the prometheus given to this module";
      description = ''
        The prometheus package to run. `promtool` is not in it — nixpkgs puts
        that in the `cli` output.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        The time series database, as `--storage.tsdb.path`.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        The address to serve the API and the web interface on. services-flake
        defaults this to every interface; this does not.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 9090;
      description = "The TCP port to serve on.";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--storage.tsdb.retention.time=7d" ];
      description = ''
        Arguments appended to the command line, one argument per element.
      '';
    };

    settings = mkOption {
      description = ''
        The Prometheus configuration, rendered as JSON — which Prometheus
        reads, because JSON is YAML. Measured with `promtool check config`.

        See
        <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>.
        `scrape_configs`, `rule_files` and the rest pass straight through.

        The storage path and the listen address are not here: each is a
        command line argument, so that the service manager substitutes them.
      '';
      example = lib.literalExpression ''
        {
          scrape_configs = [
            {
              job_name = "self";
              static_configs = [ { targets = [ "127.0.0.1:9090" ]; } ];
            }
          ];
        }
      '';
      default = { };
      type = types.submodule {
        freeformType = types.attrsOf types.anything;

        options.global = mkOption {
          default = { };
          description = "The `global` section, which every scrape job inherits.";
          type = types.submodule {
            freeformType = types.attrsOf types.anything;
            options = {
              scrape_interval = mkOption {
                type = types.str;
                default = "15s";
                description = "How often to scrape a target.";
              };
              evaluation_interval = mkOption {
                type = types.str;
                default = "15s";
                description = "How often to evaluate a rule.";
              };
            };
          };
        };
      };
    };
  };

  config = lib.mkMerge [
    {
      configData."prometheus.json".text = builtins.toJSON cfg.settings;

      process.argv = [
        (lib.getExe cfg.package)
        "--config.file=${config.configData."prometheus.json".path}"
        "--storage.tsdb.path=${cfg.dataDir}"
        "--web.listen-address=${cfg.listenAddress}:${toString cfg.port}"
      ]
      ++ cfg.extraFlags;
    }

    (lib.optionalAttrs (options ? dinit) {
      prometheus.dataDir = lib.mkDefault config.dinit.stateDir;
      dinit.dirs.${cfg.dataDir}.mode = "0700";
      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
