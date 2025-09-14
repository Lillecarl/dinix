{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.dinit;

  serviceType = types.submodule {
    freeformType = types.attrsOf types.str;
    options = {
      type = mkOption {
        type = types.enum [
          "process"
          "bgprocess"
          "scripted"
          "internal"
          "triggered"
        ];
        default = "process";
        description = "Service type";
      };
      command = mkOption {
        type = types.nullOr types.str;
        description = "Command to run";
        default = null;
      };
      options = mkOption {
        type = lib.types.listOf lib.types.str;
        description = "List of dinit service options";
        default = [ ];
        apply = lib.concatStringsSep " ";
      };
      restart = mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
  };

in
{
  options.dinit = {
    services = mkOption {
      type = types.attrsOf serviceType;
      default = { };
      description = "dinit services configuration";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.dinit;
      description = "dinit package to use";
    };
  };

  options.out =
    let
      mkDerivationOption =
        name:
        lib.mkOption {
          description = name;
          type = lib.types.package;
        };
    in
    {
      serviceDir = mkDerivationOption "dinit service directory";
      userScript = mkDerivationOption "dinit script";
    };

  options.lib = mkOption {
    type = lib.types.attrs;
    description = "Put whatever you want in here";
    default = { };
  };

  config.out =
    let
      toDinitKeyBalue =
        attrs:
        lib.generators.toKeyValue {
          mkKeyValue = lib.generators.mkKeyValueDefault { } " = ";
        } attrs;
    in
    {
      # serviceDir = pkgs.writeMultipleFiles "dinit-configs" (
      #   lib.mapAttrs (n: v: {
      #     content = toDinitKeyBalue v;
      #   }) config.dinit.services
      # );
      serviceDir = pkgs.writeMultipleFiles "dinit-configs" (
        lib.pipe config.dinit.services [
          (lib.filterAttrsRecursive (n: v: v != null))
          (lib.mapAttrs (
            n: v: {
              content = toDinitKeyBalue v;
            }
          ))
        ]
      );

      userScript =
        pkgs.writeScriptBin "dinit-user" # execline
          ''
            #! ${lib.getExe' pkgs.execline "execlineb"}
            elgetpositionals
            ${lib.getExe' pkgs.dinit "dinit"} --user --services-dir ${config.out.serviceDir} $@
          '';
    };
}
