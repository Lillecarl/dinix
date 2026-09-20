# Mosquitto, as a NixOS Modular Service.
#
# Options ported from devenv's src/modules/services/mosquitto.nix, which is
# Apache-2.0. See services/redis.nix for the shape and PORTING.md for what
# changes on the way across.
{ mosquitto }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.mosquitto;
in
{
  _class = "service";

  options.mosquitto = {
    package = mkOption {
      type = types.package;
      default = mosquitto;
      defaultText = lib.literalMD "the mosquitto given to this module";
      description = "The mosquitto package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where a persistent broker keeps `mosquitto.db`. Unused while
        {option}`mosquitto.persistence` is false.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    bind = mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = "The address to listen on, or null for every interface.";
    };

    port = mkOption {
      type = types.port;
      default = 1883;
      description = "The TCP port to accept MQTT connections on.";
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = "root";
      description = ''
        The account mosquitto changes to, or null to leave its own default.

        That default is the trap this replaces: started as root, mosquitto
        drops privileges to `mosquitto`, falls back to `nobody` where no such
        account exists, and then cannot write the persistence file into a
        directory root made — "Error saving in-memory database, unable to
        remove stale tmp file mosquitto.db.new, error Permission denied",
        with the broker still running and answering. `root` keeps it as
        whoever started it, and started by anyone else it is a no-op:
        measured, mosquitto neither warns nor fails.
      '';
    };

    allowAnonymous = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether a client may connect without a password. devenv's module
        always does; this makes it a choice, and a broker that says false
        needs a `password_file` through
        {option}`mosquitto.extraConfig`.
      '';
    };

    persistence = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to keep retained messages and durable subscriptions across a
        restart.

        The file goes in {option}`mosquitto.dataDir`, and the way it gets
        there is worth knowing: mosquitto takes `persistence_location` in its
        configuration file and nowhere else, so a state path cannot reach it —
        see PORTING.md. Left unset it writes to the working directory, which
        the service manager does substitute: `working-dir` under dinit,
        `WorkingDirectory` under systemd.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = "max_queued_messages 1000";
      description = "Appended to the generated `mosquitto.conf` verbatim.";
    };
  };

  config = lib.mkMerge [
    {
      configData."mosquitto.conf".text = ''
        allow_anonymous ${lib.boolToString cfg.allowAnonymous}
        listener ${toString cfg.port}${lib.optionalString (cfg.bind != null) " ${cfg.bind}"}
        persistence ${lib.boolToString cfg.persistence}
        log_dest stderr
        ${lib.optionalString (cfg.user != null) "user ${cfg.user}"}
        ${cfg.extraConfig}
      '';

      process.argv = [
        (lib.getExe cfg.package)
        "-c"
        config.configData."mosquitto.conf".path
      ];
    }

    (lib.optionalAttrs (options ? dinit) {
      mosquitto.dataDir = lib.mkDefault config.dinit.stateDir;

      # mkIf and not optionalAttrs around the whole block: which attributes
      # a service defines cannot depend on that service's own configuration.
      # The freeform merge has to know the shape before it evaluates a value,
      # so `lib.optionalAttrs cfg.persistence { dinit = …; }` is an infinite
      # recursion. mkIf is decided after the shape is.
      dinit.dirs = lib.mkIf cfg.persistence { ${cfg.dataDir}.mode = "0700"; };

      dinit.service = {
        working-dir = lib.mkIf cfg.persistence cfg.dataDir;
        dinix.critical = lib.mkDefault false;
      };
    })
  ];

  meta.maintainers = [ ];
}
