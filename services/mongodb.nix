# mongodb, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/mongodb.nix, which is MIT.
# See services/redis.nix for the shape and PORTING.md for what changes on the
# way across.
#
# mongodb-ce is the SSPL-licensed community server, and nixpkgs marks it
# unfree: a configuration that uses this module needs `config.allowUnfree`.
{ mongodb }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.mongodb;
in
{
  _class = "service";

  options.mongodb = {
    package = mkOption {
      type = types.package;
      default = mongodb;
      defaultText = lib.literalMD "the mongodb given to this module";
      description = "The mongod package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where mongod keeps its databases.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    bind = mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = "The address to listen on, or null for every interface.";
    };

    port = mkOption {
      type = types.port;
      default = 27017;
      description = "The TCP port to accept connections on.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--wiredTigerCacheSizeGB"
        "1"
      ];
      description = "Arguments appended to the command line, one argument per element.";
    };
  };

  config = lib.mkMerge [
    {
      # No configuration file: mongod takes its storage path on the command
      # line, which is the one place a service manager substitutes. A
      # mongod.conf would have to hold the path literally and so could not move
      # with DINIX_STATE_DIR. See PORTING.md.
      process.argv = [
        (lib.getExe' cfg.package "mongod")
        "--dbpath"
        cfg.dataDir
        # mongod makes a Unix socket in /tmp by default, and an unprivileged
        # user in a container cannot write there, so it fails to set up its
        # transport at all. The state directory is the one place that is always
        # writable, and the socket belongs under it anyway.
        "--unixSocketPrefix"
        cfg.dataDir
        "--port"
        (toString cfg.port)
      ]
      ++ lib.optionals (cfg.bind != null) [
        "--bind_ip"
        cfg.bind
      ]
      ++ cfg.extraArgs;
    }

    (lib.optionalAttrs (options ? dinit) {
      mongodb.dataDir = lib.mkDefault config.dinit.stateDir;
      dinit.dirs.${cfg.dataDir}.mode = "0700";
      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
