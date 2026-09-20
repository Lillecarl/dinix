# Mailpit, as a NixOS Modular Service.
#
# Options ported from devenv's src/modules/services/mailpit.nix, which is
# Apache-2.0. See services/redis.nix for the shape and PORTING.md for what
# changes on the way across.
{ mailpit }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.mailpit;
in
{
  _class = "service";

  options.mailpit = {
    package = mkOption {
      type = types.package;
      default = mailpit;
      defaultText = lib.literalMD "the mailpit given to this module";
      description = "The mailpit package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where the message database goes.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    database = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/mailpit.db";
      description = ''
        The message database.

        The empty string is not "in memory": mailpit then makes a temporary
        SQLite file under `$TMPDIR` instead, and dies with
        `open /tmp/mailpit-….db: permission denied` wherever that directory is
        not writable — which a container run as another account is. Name a
        path unless something else provides one.
      '';
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        The address for both listeners. mailpit itself defaults to every
        interface; this does not.
      '';
    };

    uiPort = mkOption {
      type = types.port;
      default = 8025;
      description = "The TCP port for the web interface and the API.";
    };

    smtpPort = mkOption {
      type = types.port;
      default = 1025;
      description = "The TCP port to accept mail on.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--max=500" ];
      description = ''
        Arguments appended to the command line, one argument per element.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # No configuration file at all: mailpit takes everything as an
      # argument, which is the easiest kind of service to make relocatable.
      process.argv = [
        (lib.getExe cfg.package)
        "--listen"
        "${cfg.bind}:${toString cfg.uiPort}"
        "--smtp"
        "${cfg.bind}:${toString cfg.smtpPort}"
      ]
      ++ lib.optionals (cfg.database != "") [
        "--database"
        cfg.database
      ]
      ++ cfg.extraArgs;
    }

    (lib.optionalAttrs (options ? dinit) {
      mailpit.dataDir = lib.mkDefault config.dinit.stateDir;
      dinit.dirs = lib.optionalAttrs (cfg.database != "") {
        ${cfg.dataDir}.mode = "0700";
      };
      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
