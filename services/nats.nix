# nats-server, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/nats-server.nix, which is
# MIT, and devenv's src/modules/services/nats.nix, which is Apache-2.0. See
# services/redis.nix for the shape and PORTING.md for what changes on the way
# across.
{ nats-server }:

{
  config,
  options,
  name,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.nats;
in
{
  _class = "service";

  options.nats = {
    package = mkOption {
      type = types.package;
      default = nats-server;
      defaultText = lib.literalMD "the nats-server given to this module";
      description = "The nats-server package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where JetStream keeps its streams.

        Unused while {option}`nats.jetstream` is false: a NATS server without
        JetStream writes nothing. Defaults to the state directory the service
        manager names, where it names one. See {option}`redis.dataDir`.
      '';
    };

    jetstream = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to turn on JetStream, which is persistence: streams, key-value
        buckets and object stores. Off is the upstream default, and a server
        without it holds nothing across a restart.

        The store directory reaches the server as `-sd` rather than through
        {option}`nats.settings`.`jetstream.store_dir`, because the service
        manager substitutes a command line and not a file.
      '';
    };

    settings = mkOption {
      description = ''
        The NATS configuration, rendered as JSON — which NATS reads, because
        its own format is a superset of it.

        See <https://docs.nats.io/running-a-nats-service/configuration>. An
        attribute this module does not declare passes straight through.
      '';
      default = { };
      example = lib.literalExpression ''
        {
          port = 14222;
          jetstream.max_file = "10G";
          cluster = {
            name = "cluster";
            port = 14248;
            routes = [ "nats://localhost:14248" ];
          };
        }
      '';
      type = types.submodule {
        freeformType = types.attrsOf types.anything;

        options = {
          server_name = mkOption {
            type = types.str;
            default = name;
            defaultText = lib.literalMD "the service name";
            description = ''
              What this server calls itself. It has to be unique in a cluster.
            '';
          };

          host = mkOption {
            type = types.str;
            default = "127.0.0.1";
            example = "0.0.0.0";
            description = ''
              The address to accept client connections on. NATS itself defaults
              to every interface; this follows devenv and does not.
            '';
          };

          port = mkOption {
            type = types.port;
            default = 4222;
            description = "The TCP port to accept client connections on.";
          };

          monitor_port = mkOption {
            type = types.port;
            default = 8222;
            description = ''
              The HTTP monitoring port, which serves `/healthz`, `/varz` and
              the rest. It is the only readiness answer NATS gives.
            '';
          };
        };
      };
    };
  };

  config = lib.mkMerge [
    {
      configData."nats.conf".text = builtins.toJSON cfg.settings;

      # Always a configuration file, because every option above lives in it.
      # An empty one would not do: `nats-server -c` on a file holding `{}`
      # exits 1 with "config has no values or is empty".
      process.argv = [
        (lib.getExe cfg.package)
        "-c"
        config.configData."nats.conf".path
      ]
      ++ lib.optionals cfg.jetstream [
        "-js"
        "-sd"
        cfg.dataDir
      ];
    }

    (lib.optionalAttrs (options ? dinit) {
      nats.dataDir = lib.mkDefault config.dinit.stateDir;

      dinit.dirs = lib.optionalAttrs cfg.jetstream {
        ${cfg.dataDir}.mode = "0700";
      };

      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
