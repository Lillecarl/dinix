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
        type = dinixStringLikePlusType;
        description = "See DINIT-SERVICE(5)";
        default = null;
      }
      // attrs
    );

  dinixStringLikePlusType = mkOptionType {
    name = "stringLikePlus";
    description = "Something stringlike + numbers";
    descriptionClass = "noun";
    check = isStringLikePlus;
    merge = mergeEqualOption;
  };
  dinixListType = types.nullOr (types.listOf dinixStringLikePlusType);

  isStringLikePlus =
    value: value == null || (!isList value && strings.isConvertibleWithToString value);
  toStringPlus = value: if isBool value then boolToString value else toString value;

  # Environment configuration type.
  envfileType = types.submodule (
    { config, ... }:
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

  serviceType = types.submodule (
    { config, ... }:
    {
      # This covers all all options from the dinit-service manpage
      # If not immidiately obvious from their docs: Options documented as ending
      # with a colon (depends-on: for example) should be nix lists.
      freeformType = types.attrsOf (types.either dinixListType dinixStringLikePlusType);
      # Some types get special treatment
      options = {
        type = mkDinitOption {
          default = "process";
        };
        command = mkDinitOption {
          apply = x: (if isDerivation x then getExe x else x);
        };
        stop-command = mkDinitOption {
          apply = x: (if isDerivation x then getExe x else x);
        };
        env-file = mkDinitOption {
          type = types.nullOr (types.either types.path envfileType);
          apply = (value: if value.enable or false then value.file else value);
        };
        text = mkDinitOption {
          type = types.str;
          internal = true;
        };
      };
      config =
        let
          options = pipe config [
            attrsToList
            (filter (opt: opt.name != "text" && opt.value != null)) # Don't process text recursively
          ];
          toKV =
            name: value:
            if hasPrefix "@" name then "${name} ${toStringPlus value}" else "${name} = ${toStringPlus value}";
        in
        {
          text = concatLines (
            # Make lines of all "string-like" options
            (pipe options [
              (filter (opt: isStringLikePlus opt.value))
              (map (opt: toKV opt.name opt.value))
            ])
            # Make lines of all list options
            ++ (pipe options [
              (filter (opt: isList opt.value))
              (map (opt: map (listVal: "${opt.name}: ${toStringPlus listVal}") opt.value))
              flatten
            ])
          );
        };
    }
  );
in
{
  options.name = mkOption {
    type = types.str;
    default = "dinixLauncher";
    description = "What to call the dinix launcher script";
  };

  options.verifyConfig = mkOption {
    type = types.bool;
    default = true;
    description = "Whether to call dinitcheck before passing build";
  };

  options.services = mkOption {
    type = types.attrsOf serviceType;
    default = { };
    description = "dinit services configuration, see dinit-service(5)";
  };

  options.package =
    let
      util-linuxMiniMinimal = pkgs.util-linuxMinimal.override {
        capabilitiesSupport = false;
        cryptsetup = null;
        cryptsetupSupport = false;
        ncurses = null;
        ncursesSupport = false;
        nlsSupport = false;
        pamSupport = false;
        shadow = null;
        shadowSupport = false;
        systemd = null;
        systemdSupport = false;
        translateManpages = false;
        withLastlog = false;
        writeSupport = false;
      };
    in
    mkOption {
      type = types.package;
      default = pkgs.dinit.override { util-linux = util-linuxMiniMinimal; };
    };

  options.env-file = mkOption {
    type = types.nullOr (types.either types.path envfileType);
    apply = (value: if value.enable or false then value.file else value);
    default = null;
  };

  options.dinitLauncher = mkOption {
    description = "dinit execline launcher script";
    type = types.package;
  };
  options.containerLauncher = mkOption {
    description = "dinit execline container launcher script";
    type = types.package;
  };

  options.internal = mkOption {
    type = types.anything;
    description = ''
      Here you can find various intermediate representations for mangling
      options into a derivation containing a complete dinit configuration
    '';
    internal = true;
    default = { };
  };

  # Make boot service internal by default
  config.services.boot.type = mkDefault "internal";

  # Intermediate steps for going from Nix options into dinit configuration derivation
  config.internal = rec {
    # Write service files and friends to disk
    services-dir = pkgs.writeMultipleFiles {
      name = "services-dir";
      files = mapAttrs (serviceName: serviceValue: { content = serviceValue.text; }) config.services;
      # Config verification
      extraCommands =
        optionalString config.verifyConfig # bash
          ''
            ${getExe' config.package "dinitcheck"} ${envfileArg} --services-dir $out
          '';
    };

    envfileArg = if config.env-file != null then "--env-file ${config.env-file}" else "";
  };

  config.dinitLauncher =
    pkgs.writeExeclineBin config.name # execline
      ''
        elgetpositionals
        ${getExe' pkgs.dinit "dinit"} ${config.internal.envfileArg} --services-dir ${config.internal.services-dir} $@
      '';

  config.containerLauncher =
    pkgs.writeExeclineBin config.name # execline
      ''
        elgetpositionals
        foreground { mkdir -p /run }
        ${getExe config.dinitLauncher} --container $@
      '';
}
