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
        type = types.nullOr (types.listOf types.str);
        # No apply function - handled in finalServices
      };
      rdepends-on = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        description = "Reverse depends-on (like systemd's RequiredBy vs Requires)";
        # No apply function - processed and removed
      };
      depends-ms = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        # No apply function - handled in finalServices
      };
      rdepends-ms = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        description = "Reverse depends-ms (like systemd's RequiredBy vs Requires)";
        # No apply function - processed and removed
      };
      waits-for = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        # No apply function - handled in finalServices
      };
      rwaits-for = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        description = "Reverse waits-for (like systemd's RequiredBy vs Requires)";
        # No apply function - processed and removed
      };
      after = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        # No apply function - handled in finalServices
      };
      before = mkDinitOption {
        type = types.nullOr (types.listOf types.str);
        # No apply function - handled in finalServices
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
    };
  };

  # Process reverse dependencies and merge them into the final services
  processReverseDependencies =
    services:
    let
      # Reverse dependency mappings: reverse attr -> target attr
      reverseMappings = {
        "rdepends-on" = "depends-on";
        "rdepends-ms" = "depends-ms";
        "rwaits-for" = "waits-for";
      };

      # Collect all reverse dependencies for each mapping
      collectReverseDeps =
        reverseAttr: targetAttr:
        lib.pipe services [
          # Extract reverse dependencies from each service
          (lib.mapAttrsToList (
            serviceName: serviceConfig:
            lib.optionals (serviceConfig.${reverseAttr} != null) (
              map (target: { inherit target serviceName; }) serviceConfig.${reverseAttr}
            )
          ))
          # Flatten the list
          lib.flatten
          # Group by target service
          (lib.groupBy (x: x.target))
          # Convert to attrset of lists of service names
          (lib.mapAttrs (target: deps: map (x: x.serviceName) deps))
        ];

      # Collect all reverse dependencies
      allReverseDeps = lib.mapAttrs collectReverseDeps reverseMappings;

      # Merge reverse dependencies into target attributes for each service
      mergeReverseDeps =
        serviceName: serviceConfig:
        let
          # Process each reverse dependency type
          processReverseType =
            acc: reverseAttr: targetAttr:
            let
              # Get services that should depend on this service (reverse deps)
              incomingDeps = allReverseDeps.${reverseAttr}.${serviceName} or [ ];

              # Get existing dependencies as list, handling null case
              existingDeps = if acc.${targetAttr} == null then [ ] else acc.${targetAttr};

              # Combine and deduplicate dependencies
              allDeps = lib.unique (existingDeps ++ incomingDeps);

              # Keep as list for now
              finalDeps = if allDeps == [ ] then null else allDeps;
            in
            acc // { ${targetAttr} = finalDeps; };

          # Apply all reverse dependency processing using fold over the mappings
          processedConfig = lib.foldlAttrs processReverseType serviceConfig reverseMappings;
        in
        # Remove all reverse dependency attributes from final output
        removeAttrs processedConfig (lib.attrNames reverseMappings);
    in
    lib.mapAttrs mergeReverseDeps services;

  # Apply list-to-string conversions for final output
  applyListConversions =
    services:
    let
      # List of attributes that should be converted from lists to space-separated strings
      listAttrs = [
        "depends-on"
        "depends-ms"
        "waits-for"
        "after"
        "before"
      ];

      convertService =
        serviceName: serviceConfig:
        lib.mapAttrs (
          attrName: attrValue: if lib.elem attrName listAttrs then nullOrListApply attrValue else attrValue
        ) serviceConfig;
    in
    lib.mapAttrs convertService services;
in
{
  options.dinit = {
    services = mkOption {
      type = types.attrsOf serviceType;
      default = { };
      description = "dinit services configuration";
    };

    # Internal option for processed services
    finalServices = mkOption {
      type = types.anything;
      internal = true;
      description = "Final services configuration with reverse dependencies processed";
      apply = applyListConversions;
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
  config.dinit.finalServices = processReverseDependencies config.dinit.services;

  config.out =
    let
      toDinitKeyValue =
        attrs:
        lib.generators.toKeyValue {
          mkKeyValue = lib.generators.mkKeyValueDefault { } " = ";
        } attrs;
    in
    {
      serviceDir = pkgs.writeMultipleFiles "dinit-configs" (
        lib.pipe config.dinit.finalServices [
          # Remove all null options
          (lib.filterAttrsRecursive (n: v: v != null))
          # Set content to dinit style key = value format
          (lib.mapAttrs (
            n: v: {
              content = toDinitKeyValue v;
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
