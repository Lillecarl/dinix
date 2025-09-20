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

  # Environment configuration type.
  envfileType = types.submodule (
    { name, config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "If we should add env-file argument to launcher script";
        };
        clear = mkOption {
          type = types.bool;
          default = false;
          description = "Clear all environment variables";
        };
        variables = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Environment variables to set";
        };
        unset = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of variables to unset";
        };
        import = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of variables to import";
        };
        text = mkOption {
          type = types.str;
          description = "Rendered env-file text";
          internal = true;
        };
        file = mkOption {
          type = types.package;
          description = "Rendered env-file file";
          internal = true;
        };
      };
      config = {
        # Set enable if anything isn't it's default value
        enable = lib.mkDefault (
          config.clear == true || config.variables != { } || config.unset != [ ] || config.import != [ ]
        );
        text = ''
          # dinit environment file. See DINIT(8)
          ${lib.optionalString (config.clear) "!clear"}
          ${lib.concatLines (lib.map (x: "!unset ${x}") config.unset)}
          ${lib.generators.toKeyValue {
            mkKeyValue = lib.generators.mkKeyValueDefault { } "=";
          } config.variables}
          ${lib.concatLines (lib.map (x: "!import ${x}") config.import)}
        '';
        file = pkgs.writeText "env-file" config.text;
      };
    }
  );

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
          type = types.nullOr (types.either types.str types.package);
          apply = (x: (if isDerivation x then getExe x else x));
        };
        stop-command = mkDinitOption {
          type = types.nullOr (types.either types.str types.package);
          apply = (x: (if isDerivation x then getExe x else x));
        };
        working-dir = mkDinitOption {
          type = types.nullOr types.path;
        };
        run-as = mkDinitOption {
          type = types.nullOr (types.either types.str types.int);
        };
        env-file = mkDinitOption {
          type = types.nullOr (types.either types.path envfileType);
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
        include = mkDinitOption {
          type = types.nullOr types.path;
        };
        include-opt = mkDinitOption {
          type = types.nullOr types.path;
        };
        # dinit options we won't implement:
        # * inittab-id
        # * inittab-line
        # * rlimit-nofile
        # * rlimit-core
        # * rlimit-data
        # * rlimit-addrspace
        # * run-in-cgroup
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

  options.env-file = mkOption {
    type = types.either types.path envfileType;
    default = { };
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
    cleanedServices = lib.pipe config.services [
      # Remove all null options
      (lib.filterAttrsRecursive (n: v: v != null))
      # Rename options from nix-friendly names/keys to dinit keys
      (mapServicesOptions (
        optionName: optionValue: {
          name = if lib.hasAttr optionName renameOpts then renameOpts.${optionName} else optionName;
          value = optionValue;
        }
      ))
    ];

    finalServices = lib.pipe cleanedServices [
      # Convert diropt into directory path
      (lib.mapAttrs (
        serviceName: serviceValue:
        lib.mapAttrs (
          optionName: optionValue: if isDirOpt optionName then "${serviceName}-${optionName}" else optionValue
        ) serviceValue
      ))
      # Convert env-file attrs to file path
      (lib.mapAttrs (
        serviceName: serviceValue:
        lib.mapAttrs (
          optionName: optionValue:
          if optionName == "env-file" then "env-files/${serviceName}.env" else optionValue
        ) serviceValue
      ))
      # Remove name option since it's only internal
      (lib.mapAttrs (
        serviceName: serviceValue:
        lib.filterAttrs (optionName: optionValue: optionName != "name") serviceValue
      ))
    ];

    # Convert mangled service descriptions into files
    serviceFiles = lib.mapAttrs (n: v: {
      content = toDinitService v;
    }) config.internal.finalServices;

    # extract .d options into attrset
    depsFiles = lib.foldlAttrs (
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
    ) { } cleanedServices;

    envFiles = lib.pipe cleanedServices [
      # Only if service has env-file option set
      (filterAttrs (n: v: (v.env-file or false) != false))
      # Make env-files available under env-files/servicename in services-dir
      (mapAttrs' (
        serviceName: serviceValue: {
          name = "env-files/${serviceName}.env";
          value.content = serviceValue.env-file.text;
        }
      ))
    ];

    # Write service files and friends to disk
    services-dir = pkgs.writeMultipleFiles {
      name = "services-dir";
      files = (
        # Service files
        serviceFiles
        # Dependency files
        // config.internal.depsFiles
        # Env files
        // config.internal.envFiles
      );
      # Config verification
      extraCommands = # bash
        ''
          ${lib.getExe' config.package "dinitcheck"} ${lib.optionalString config.env-file.enable "--env-file ${config.env-file.file}"} --services-dir $out
        '';
    };

  };

  config.dinitLauncher =
    pkgs.writeExeclineBin "dinitLauncher" # execline
      ''
        elgetpositionals
        ${lib.getExe' pkgs.dinit "dinit"} ${lib.optionalString config.env-file.enable "--env-file ${config.env-file.file}"} --services-dir ${config.internal.services-dir} $@
      '';
}
