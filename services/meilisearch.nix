# meilisearch, as a NixOS Modular Service.
#
# Options ported from devenv's src/modules/services/meilisearch.nix, which is
# Apache-2.0. See services/redis.nix for the shape and PORTING.md for what
# changes on the way across.
{ meilisearch, coreutils }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.meilisearch;
in
{
  _class = "service";

  options.meilisearch = {
    package = mkOption {
      type = types.package;
      default = meilisearch;
      defaultText = lib.literalMD "the meilisearch given to this module";
      description = "The meilisearch package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where the index database and its dumps go.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "The address to listen on.";
    };

    listenPort = mkOption {
      type = types.port;
      default = 7700;
      description = "The TCP port to accept connections on.";
    };

    environment = mkOption {
      type = types.enum [
        "development"
        "production"
      ];
      default = "development";
      description = ''
        The running environment.

        `production` makes meilisearch require a master key, which this module
        does not set: leave it at `development` unless a key is provided some
        other way.
      '';
    };

    noAnalytics = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to disable anonymous telemetry.";
    };

    logLevel = mkOption {
      type = types.str;
      default = "INFO";
      description = "How much meilisearch logs.";
    };

    maxIndexSize = mkOption {
      type = types.str;
      default = "107374182400";
      description = "The maximum index size, in bytes or with a base unit.";
    };
  };

  config = lib.mkMerge [
    {
      # meilisearch is configured only through MEILI_* environment variables,
      # and the database path is one of them. `env` carries them, because a
      # service manager substitutes a command line and meilisearch reads no
      # configuration file. See services/caddy.nix.
      process.argv = [
        (lib.getExe' coreutils "env")
        "MEILI_DB_PATH=${cfg.dataDir}/data"
        "MEILI_DUMP_DIR=${cfg.dataDir}/dumps"
        "MEILI_HTTP_ADDR=${cfg.listenAddress}:${toString cfg.listenPort}"
        "MEILI_ENV=${cfg.environment}"
        "MEILI_NO_ANALYTICS=${lib.boolToString cfg.noAnalytics}"
        "MEILI_LOG_LEVEL=${cfg.logLevel}"
        "MEILI_MAX_INDEX_SIZE=${cfg.maxIndexSize}"
        (lib.getExe' cfg.package "meilisearch")
      ];
    }

    (lib.optionalAttrs (options ? dinit) {
      meilisearch.dataDir = lib.mkDefault config.dinit.stateDir;
      dinit.dirs.${cfg.dataDir}.mode = "0700";
      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
