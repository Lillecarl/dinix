# mailhog, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/mailhog.nix, which is MIT.
# See services/redis.nix for the shape and PORTING.md for what changes on the
# way across. mailpit is the sibling port; mailhog is the older project and
# keeps nothing on disk.
{ mailhog }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.mailhog;
in
{
  _class = "service";

  options.mailhog = {
    package = mkOption {
      type = types.package;
      default = mailhog;
      defaultText = lib.literalMD "the mailhog given to this module";
      description = "The mailhog package to run.";
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = "The address for all three listeners.";
    };

    apiPort = mkOption {
      type = types.port;
      default = 8025;
      description = "The TCP port for the HTTP API.";
    };

    uiPort = mkOption {
      type = types.port;
      default = 8025;
      description = "The TCP port for the web interface.";
    };

    smtpPort = mkOption {
      type = types.port;
      default = 1025;
      description = "The TCP port to accept mail on.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "-invite-jim" ];
      description = "Arguments appended to the command line, one argument per element.";
    };
  };

  config = lib.mkMerge [
    {
      # No configuration file and nothing kept on disk, which is the easiest
      # kind of service to make relocatable. The binary is named MailHog, so
      # this names it rather than letting getExe guess.
      process.argv = [
        (lib.getExe' cfg.package "MailHog")
        "-api-bind-addr"
        "${cfg.bind}:${toString cfg.apiPort}"
        "-ui-bind-addr"
        "${cfg.bind}:${toString cfg.uiPort}"
        "-smtp-bind-addr"
        "${cfg.bind}:${toString cfg.smtpPort}"
      ]
      ++ cfg.extraArgs;
    }

    (lib.optionalAttrs (options ? dinit) {
      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
