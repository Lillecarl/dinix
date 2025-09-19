{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
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

  serviceType = types.submodule (
    { name, ... }:
    {
      freeformType = types.attrsOf types.str;
      options = {
        name = mkOption {
          default = name;
          internal = true;
        };
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
        depends-on-d = mkDinitOption {
          type = types.nullOr (types.listOf types.str);
        };
        depends-ms-d = mkDinitOption {
          type = types.nullOr (types.listOf types.str);
        };
        waits-for-d = mkDinitOption {
          type = types.nullOr (types.listOf types.str);
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
        include = mkDinitOption {
          type = types.nullOr types.path;
        };
        include-opt = mkDinitOption {
          type = types.nullOr types.path;
        };
      };
    }
  );
in
{
  options.services = mkOption {
    type = types.attrsOf serviceType;
    default = { };
    description = "dinit services configuration";
  };

  options.package = mkOption {
    type = types.package;
    default = pkgs.dinit;
    description = "dinit package to use";
  };

  options.dinitLauncher = mkOption {
    description = "dinit execline launcher script";
    type = types.package;
  };

  options.internal = mkOption {
    type = types.attrs;
    description = ''
      Here you can find various intermediate representations for mangling
      options into a derivation containing a complete dinit configuration
    '';
    internal = true;
    default = { };
  };

  # Make boot service internal by default
  config.services.boot.type = lib.mkDefault "internal";

  # Intermediate steps for going from Nix options into dinit configuration derivation
  config.internal = rec {
    # Set of options to rename from their easily typed Nix names
    # into their corresponding dinit names
    renameOpts = {
      "depends-on-d" = "depends-on.d";
      "depends-ms-d" = "depends-ms.d";
      "waits-for-d" = "waits-for.d";
      "include" = "@include";
      "include-opt" = "@include-opt";
    };

    # Check if option has the -d suffix, is a directory option
    isDirOpt =
      optionName:
      lib.any (x: lib.hasSuffix x optionName) [
        "-d"
        ".d"
      ];

    # Apply mapAttrs' (prime) to all options of all services. "function" must
    # return a nameValuePair.
    mapServicesOptions =
      function: services:
      (lib.mapAttrs (serviceName: serviceValue: lib.mapAttrs' function serviceValue) services);

    # Extracts .d lists into a flattened attrset for creating dependency files.
    extractDAttributes =
      services:
      lib.foldlAttrs (
        acc: serviceName: service:
        lib.foldlAttrs (
          acc': attrName: deps:
          if lib.hasSuffix ".d" attrName then
            acc'
            // lib.listToAttrs (
              map (dep: {
                name = "${serviceName}-${attrName}/${dep}";
                value = {
                  content = "";
                };
              }) deps
            )
          else
            acc'
        ) acc service
      ) { } services;

    # Converts a Nix dinit spec to a dinit "KV" spec
    toDinitService =
      attrs:
      let
        kvAttrs = lib.filterAttrs (n: v: !lib.hasPrefix "@" n && lib.typeOf != "list") attrs;
        metaAttrs = lib.filterAttrs (n: v: lib.hasPrefix "@" n) attrs;

        keyValueStr = lib.generators.toKeyValue {
          mkKeyValue = lib.generators.mkKeyValueDefault { } " = ";
        } kvAttrs;

        metaValueStr = lib.generators.toKeyValue {
          mkKeyValue = lib.generators.mkKeyValueDefault { } " ";
        } metaAttrs;

      in
      # dinit
      ''
        # dinit service configuration see dinit-service(5)

        # Nix rendered configuration:
        ${keyValueStr}
        # Optional includes for overrides or other shenanigans:
        ${metaValueStr}
      '';

    # Rename option names and remove null option values
    cleaned = lib.pipe config.services [
      # Rename options from nix-friendly names/keys to dinit keys
      (mapServicesOptions (
        optionName: optionValue: {
          name = if lib.hasAttr optionName renameOpts then renameOpts.${optionName} else optionName;
          value = optionValue;
        }
      ))
      # Remove all null options
      (lib.filterAttrsRecursive (n: v: v != null))
    ];

    # extract .d options into attrset
    deps = lib.pipe cleaned [
      extractDAttributes
    ];

    final = lib.pipe cleaned [
      # Convert diropt into directory path
      (lib.mapAttrs (
        serviceName: serviceValue:
        lib.mapAttrs (
          optionName: optionValue: if isDirOpt optionName then "${serviceName}-${optionName}" else optionValue
        ) serviceValue
      ))
      # Remove name option since it's only internal
      (lib.mapAttrs (
        serviceName: serviceValue:
        lib.filterAttrs (optionName: optionValue: optionName != "name") serviceValue
      ))
    ];

    dinitConfig = pkgs.writeMultipleFiles "dinitConfig" (

      # Intermediate steps for going from Nix options into dinit configuration derivation
      lib.pipe config.internal.final [
        # Set content to dinit style key = value format
        (lib.mapAttrs (
          n: v: {
            content = toDinitService v;
          }
        ))
      ]

      # Intermediate steps for going from Nix options into dinit configuration derivation
      // config.internal.deps
    );
  };

  config.dinitLauncher =
    pkgs.writeExeclineBin "dinitLauncher" # execline
      ''
        elgetpositionals
        ${lib.getExe' pkgs.dinit "dinit"} --services-dir ${config.internal.dinitConfig} $@
      '';
}
