{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  listToFileAttrs =
    list:
    if list == null then
      list
    else
      pkgs.writeMultipleFiles "dinit-depdir.d" (
        lib.listToAttrs (
          map (name: {
            inherit name;
            value = {
              content = "";
            };
          }) list
        )
      );

  # mkOption wrapper that sets description and default
  mkDinitOption =
    attrs:
    mkOption (
      {
        description = "See DINIT-SERVICE(5)";
        default = null;
      }
      // attrs
    );
  # Module option apply function used to convert lists to space separated strings
  nullOrListApply = x: if lib.typeOf x == "list" then lib.concatStringsSep " " x else x;

  serviceType = types.submodule {
    freeformType = types.attrsOf types.str;
    options = {
      type = mkDinitOption {
        type = types.enum [
          "process"
          "bgprocess"
          "scripted"
          "internal"
          "triggered"
        ];
        default = "process";
      };
      command = mkDinitOption {
        type = types.nullOr types.str;
      };
      stop-command = mkDinitOption {
        type = types.nullOr types.str;
      };
      working-dir = mkDinitOption {
        type = types.nullOr types.str;
      };
      run-as = mkDinitOption {
        type = types.nullOr (types.either types.str types.int);
      };
      env-file = mkDinitOption {
        type = types.nullOr types.path;
      };
      restart = mkDinitOption {
        type = types.nullOr (types.either (types.enum [ "on-failure" ]) types.bool);
      };
      smooth-recovery = mkDinitOption {
        type = types.nullOr types.bool;
      };
      restart-delay = mkDinitOption {
        type = types.nullOr types.number;
      };
      restart-limit-interval = mkDinitOption {
        type = types.nullOr types.number;
      };
      restart-limit-count = mkDinitOption {
        type = types.nullOr types.int;
      };
      start-timeout = mkDinitOption {
        type = types.nullOr types.number;
      };
      stop-timeout = mkDinitOption {
        type = types.nullOr types.number;
      };
      pid-file = mkDinitOption {
        type = types.nullOr types.path;
      };
      depends-on = mkDinitOption {
        type = types.nullOr types.str;
      };
      depends-ms = mkDinitOption {
        type = types.nullOr types.str;
      };
      waits-for = mkDinitOption {
        type = types.nullOr types.str;
      };
      "depends-on.d" = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        apply = listToFileAttrs;
      };
      "depends-ms.d" = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        apply = listToFileAttrs;
      };
      "waits-for.d" = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        apply = listToFileAttrs;
      };
      after = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        apply = nullOrListApply;
      };
      before = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        apply = nullOrListApply;
      };
      chain-to = mkDinitOption {
        type = types.nullOr types.str;
      };
      socket-listen = mkDinitOption {
        type = types.nullOr types.path;
      };
      socket-permissions = mkDinitOption {
        type = types.nullOr lib.types.int;
      };
      socket-uid = mkDinitOption {
        type = types.nullOr (types.either types.str types.int);
      };
      socket-gid = mkDinitOption {
        type = types.nullOr (types.either types.str types.int);
      };
      term-signal = mkDinitOption {
        type = types.nullOr (
          types.enum [
            "HUP"
            "INT"
            "QUIT"
            "KILL"
            "USR1"
            "USR2"
            "TERM"
            "CONT"
            "STOP"
          ]
        );
      };
      ready-notification = mkDinitOption {
        type = types.nullOr types.str;
      };
      log-type = mkDinitOption {
        type = types.nullOr (
          types.enum [
            "file"
            "buffer"
            "pipe"
            "none"
          ]
        );
      };
      logfile = mkDinitOption {
        type = types.nullOr types.path;
      };
      logfile-permissions = mkDinitOption {
        type = types.nullOr lib.types.int;
      };
      logfile-uid = mkDinitOption {
        type = types.nullOr (types.either types.str types.int);
      };
      logfile-gid = mkDinitOption {
        type = types.nullOr (types.either types.str types.int);
      };
      log-buffer-size = mkDinitOption {
        type = types.nullOr lib.types.int;
      };
      consumer-of = mkDinitOption {
        type = types.nullOr types.str;
      };
      options = mkDinitOption {
        type = types.nullOr (
          types.listOf (
            types.enum [
              "runs-on-console"
              "starts-on-console"
              "shares-console"
              "unmask-intr"
              "starts-rwfs"
              "starts-log"
              "pass-cs-fd"
              "start-interruptible"
              "skippable"
              "signal-process-only"
              "always-chain"
              "kill-all-on-stop"
            ]
          )
        );
        apply = nullOrListApply;
      };
      load-options = mkDinitOption {
        type = types.nullOr (
          types.listOf (
            types.enum [
              "export-passwd-vars"
              "export-service-name"
            ]
          )
        );
        apply = nullOrListApply;
      };
      inittab-id = mkDinitOption {
        type = types.nullOr types.str;
      };
      inittab-line = mkDinitOption {
        type = types.nullOr types.str;
      };
      rlimit-nofile = mkDinitOption {
        type = types.nullOr types.str;
      };
      rlimit-core = mkDinitOption {
        type = types.nullOr types.str;
      };
      rlimit-data = mkDinitOption {
        type = types.nullOr types.str;
      };
      rlimit-addrspace = mkDinitOption {
        type = types.nullOr types.str;
      };
      run-in-cgroup = mkDinitOption {
        type = types.nullOr types.path;
      };
      "@include" = mkDinitOption {
        type = types.nullOr types.path;
      };
      "@include-opt" = mkDinitOption {
        type = types.nullOr types.path;
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
          type = types.package;
        };
    in
    {
      serviceDir = mkDerivationOption "dinit service directory";
      script = mkDerivationOption "dinit script";
    };

  options.lib = mkOption {
    type = types.attrs;
    description = "Put whatever you want in here";
    default = { };
  };

  config.dinit.services.boot.type = lib.mkDefault "internal";
  config.out =
    let
      toDinitService =
        attrs:
        let
          kvAttrs = lib.filterAttrs (n: v: !lib.hasPrefix "@" n) attrs;
          metaAttrs = lib.filterAttrs (n: v: lib.hasPrefix "@" n) attrs;

          keyValueStr = lib.generators.toKeyValue {
            mkKeyValue = lib.generators.mkKeyValueDefault { } " = ";
          } kvAttrs;

          metaValueStr = lib.generators.toKeyValue {
            mkKeyValue = lib.generators.mkKeyValueDefault { } " ";
          } metaAttrs;

        in
        ''
          # dinit service configuration see dinit-service(5)
          ${metaValueStr}
          ${keyValueStr}
        '';
    in
    {
      serviceDir = pkgs.writeMultipleFiles "dinit-configs" (
        lib.pipe config.dinit.services [
          # Remove all null options
          (lib.filterAttrsRecursive (n: v: v != null))
          # Set content to dinit style key = value format
          (lib.mapAttrs (
            n: v: {
              content = toDinitService v;
            }
          ))
        ]
      );

      script =
        pkgs.writeExeclineBin "dinit-user" # execline
          ''
            elgetpositionals
            ${lib.getExe' pkgs.dinit "dinit"} --services-dir ${config.out.serviceDir} $@
          '';
    };
}
