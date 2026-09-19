{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    attrsToList
    concatLines
    filter
    generators
    getExe
    getExe'
    hasPrefix
    isBool
    isDerivation
    isList
    mapAttrsToList
    mergeEqualOption
    mkDefault
    mkOption
    mkOptionType
    optionalString
    pipe
    types
    ;

  dinixStringLikePlusType = mkOptionType {
    name = "stringLikePlus";
    description = "Something stringlike + numbers";
    descriptionClass = "noun";
    check = isStringLikePlus;
    merge = mergeEqualOption;
  };
  dinixListType = types.nullOr (types.listOf dinixStringLikePlusType);

  isStringLikePlus =
    value: value == null || (!isList value && lib.strings.isConvertibleWithToString value);
  toStringPlus = value: if isBool value then lib.boolToString value else toString value;

  mkDinitOption =
    attrs:
    mkOption (
      {
        type = dinixStringLikePlusType;
        description = "See DINIT-SERVICE(5)";
        default = null;
      }
      // attrs
    );

  envfileType = types.submodule (
    { config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          description = ''
            Whether to pass this file to dinit. Set by default when any other
            option in this set is not at its default.
          '';
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
          description = "List of variables to import from the ambient environment";
        };
        text = mkOption {
          type = types.str;
          description = "Rendered env-file text";
          internal = true;
        };
        file = mkOption {
          type = types.package;
          description = "Rendered env-file";
          internal = true;
        };
      };
      config = {
        enable = mkDefault (
          config.clear || config.variables != { } || config.unset != [ ] || config.import != [ ]
        );
        text = ''
          # dinit environment file. See DINIT(8)
          ${optionalString config.clear "!clear"}
          ${concatLines (map (x: "!unset ${x}") config.unset)}
          ${generators.toKeyValue {
            mkKeyValue = generators.mkKeyValueDefault { } "=";
          } config.variables}
          ${concatLines (map (x: "!import ${x}") config.import)}
        '';
        file = pkgs.writeText "env-file" config.text;
      };
    }
  );

  # A dinit service description. The freeform type covers every option in
  # dinit-service(5); the declared ones below only add conversions on top.
  # An option the manpage writes with a colon suffix (depends-on:) takes a Nix
  # list here, and each element becomes its own line.
  serviceType = types.submodule (
    { config, ... }:
    {
      freeformType = types.attrsOf (types.either dinixListType dinixStringLikePlusType);

      options = {
        type = mkDinitOption {
          default = "process";
        };
        command = mkDinitOption {
          apply = x: if isDerivation x then getExe x else x;
        };
        stop-command = mkDinitOption {
          apply = x: if isDerivation x then getExe x else x;
        };
        env-file = mkDinitOption {
          type = types.nullOr (types.either types.path envfileType);
          apply = value: if value.enable or false then value.file else value;
        };
        text = mkDinitOption {
          type = types.str;
          internal = true;
        };
      };

      config =
        let
          settings = pipe config [
            attrsToList
            # text is this attribute; including it would recurse.
            (filter (opt: opt.name != "text" && opt.value != null))
          ];
          # @include and friends are directives, not assignments.
          toKV =
            name: value:
            if hasPrefix "@" name then "${name} ${toStringPlus value}" else "${name} = ${toStringPlus value}";
        in
        {
          text = concatLines (
            (pipe settings [
              (filter (opt: isStringLikePlus opt.value))
              (map (opt: toKV opt.name opt.value))
            ])
            ++ (pipe settings [
              (filter (opt: isList opt.value))
              (map (opt: map (listVal: "${opt.name}: ${toStringPlus listVal}") opt.value))
              lib.flatten
            ])
          );
        };
    }
  );
in
{
  imports = [
    ./users.nix
  ];

  options = {
    name = mkOption {
      type = types.str;
      default = "dinixLauncher";
      description = "Derivation name for the generated wrappers.";
    };

    services = mkOption {
      type = types.attrsOf serviceType;
      default = { };
      description = "dinit services, one attribute per service. See dinit-service(5).";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.dinit;
      description = "The dinit package to configure, wrap and verify against.";
    };

    env-file = mkOption {
      type = types.nullOr (types.either types.path envfileType);
      apply = value: if value.enable or false then value.file else value;
      default = null;
      description = ''
        Environment file dinit itself reads, applied to every service. Either a
        path, or an attribute set rendered into one. See dinit(8).
      '';
    };

    verifyConfig = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to run dinit-check over the rendered services at build time.";
    };

    userWrapper = mkOption {
      type = types.package;
      description = ''
        dinit and its tools, wrapped to read this configuration straight from
        the store. For running a dinix configuration as an unprivileged user:
        `dinit --user`.
      '';
    };

    containerWrapper = mkOption {
      type = types.package;
      description = ''
        dinit as PID 1 of a container. Copies the services into /run/services,
        installs the user database, then execs `dinit --container`.
      '';
    };

    internal = mkOption {
      type = types.submodule {
        options = {
          services-dir = mkOption {
            type = types.package;
            description = "Directory holding one rendered file per service.";
          };
          envfileArg = mkOption {
            type = types.str;
            description = "The --env-file argument, or the empty string.";
          };
          usersInstallScript = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Script that installs the user database into the rootfs.";
          };
        };
      };
      description = ''
        Intermediate results on the way from these options to a derivation
        holding a complete dinit configuration.
      '';
      internal = true;
      default = { };
    };
  };

  config = {
    services.boot.type = mkDefault "internal";

    internal = {
      envfileArg = optionalString (config.env-file != null) "--env-file ${config.env-file}";

      services-dir = pkgs.runCommand "dinix-services" { } (
        concatLines (
          [ "mkdir --parents $out" ]
          ++ (mapAttrsToList (
            serviceName: service:
            "cp ${pkgs.writeText "dinix-service-${serviceName}" service.text} $out/${serviceName}"
          ) config.services)
          ++ lib.optional config.verifyConfig "${getExe' config.package "dinit-check"} ${config.internal.envfileArg} --services-dir $out"
        )
      );
    };

    userWrapper =
      pkgs.runCommand config.name
        {
          nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
          meta.mainProgram = "dinit";
        }
        ''
          mkdir --parents $out/bin
          makeBinaryWrapper ${getExe' config.package "dinit"} $out/bin/dinit \
            --add-flags "${config.internal.envfileArg} --services-dir ${config.internal.services-dir}"
          makeBinaryWrapper ${getExe' config.package "dinit-check"} $out/bin/dinit-check \
            --add-flags "${config.internal.envfileArg} --services-dir ${config.internal.services-dir}"
          ln --symbolic ${getExe' config.package "dinitctl"} $out/bin/dinitctl
          ln --symbolic ${getExe' config.package "dinit-monitor"} $out/bin/dinit-monitor
        '';

    containerWrapper = pkgs.buildEnv {
      name = "containerWrapper";
      meta.mainProgram = "dinit";
      paths = [
        (lib.hiPrio (
          pkgs.writeScriptBin "dinit" # bash
            ''
              #! ${pkgs.runtimeShell}
              set -euo pipefail
              export PATH=${
                lib.makeBinPath [
                  pkgs.coreutils
                  pkgs.rsync
                ]
              }:$PATH
              mkdir --parents /run/services
              mkdir --parents /var/log
              rsync --archive ${config.internal.services-dir}/ /run/services

              ${optionalString (config.internal.usersInstallScript != null) (
                getExe config.internal.usersInstallScript
              )}

              exec ${getExe' config.package "dinit"} \
                ${config.internal.envfileArg} \
                --services-dir /run/services \
                --container \
                "$@"
            ''
        ))
        config.package
      ];
    };
  };
}
