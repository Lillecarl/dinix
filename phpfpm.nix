# Ported from services-flake, nix/services/phpfpm.nix, which is Apache-2.0.
# The options are theirs, option for option. See PORTING.md for what changes
# on the way across.
let
  inherit (import ./service-lib.nix) multiService;
in
multiService "phpfpm" (
  {
    name,
    config,
    pkgs,
    lib,
    ...
  }:
  let
    inherit (lib) mkOption types;

    toStr =
      value:
      if true == value then
        "yes"
      else if false == value then
        "no"
      else
        toString value;

    configType =
      with types;
      attrsOf (oneOf [
        str
        int
        bool
      ]);
  in
  {
    options = {
      package = lib.mkPackageOption pkgs "php" { };

      listen = mkOption {
        type = types.either types.port types.str;
        default = "phpfpm.sock";
        description = ''
          The address on which to accept FastCGI requests.
        '';
      };

      phpOptions = mkOption {
        type = types.lines;
        default = "";
        example = ''
          date.timezone = "CET"
        '';
        description = ''
          Options appended to the PHP configuration file {file}`php.ini` used for this PHP-FPM pool.
        '';
      };

      phpEnv = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Environment variables used for this PHP-FPM pool.
        '';
        example = lib.literalExpression ''
          {
            HOSTNAME = "$HOSTNAME";
            TMP = "/tmp";
            TMPDIR = "/tmp";
            TEMP = "/tmp";
          }
        '';
      };

      extraConfig = mkOption {
        type = configType;
        default = { };
        description = ''
          PHP-FPM pool directives. Refer to the "List of pool directives" section of
          <https://www.php.net/manual/en/install.fpm.configuration.php>
          for details. Note that settings names must be enclosed in quotes (e.g.
          `"pm.max_children"` instead of `pm.max_children`).
        '';
        example = lib.literalExpression ''
          {
            "pm" = "dynamic";
            "pm.max_children" = 75;
            "pm.start_servers" = 10;
            "pm.min_spare_servers" = 5;
            "pm.max_spare_servers" = 20;
            "pm.max_requests" = 500;
          }
        '';
      };

      globalSettings = mkOption {
        type = configType;
        default = { };
        description = ''
          PHP-FPM global directives. Refer to the "List of global php-fpm.conf directives" section of
          <https://www.php.net/manual/en/install.fpm.configuration.php>
          for details. Note that settings names must be enclosed in quotes (e.g.
          `"pm.max_children"` instead of `pm.max_children`).
          Do not specify the options `error_log` or
          `daemonize` here, since they are generated.
        '';
        example = lib.literalExpression ''
          {
            "log_level" = "debug";
          }
        '';
      };
    };

    config = {
      extraConfig.listen = lib.mkDefault config.listen;

      # A php-fpm master running as root refuses to start without a pool user:
      # "[pool proto] user has not been defined", then "FPM initialization
      # failed", exit 78. It says this before any request, so the service looks
      # started and the first check is what finds it. Running unprivileged it
      # ignores both directives with a warning, so one default serves every
      # mode. Override them like any other pool directive.
      extraConfig.user = lib.mkDefault "nobody";
      extraConfig.group = lib.mkDefault "nogroup";

      outputs.dirs.${config.dataDir} = {
        # The pool's socket lives here when `listen` names one, so whoever
        # the master runs as must own the directory. The collection says who
        # that is; owner-only access is enough everywhere, because every mode
        # runs the master as the account that also asks it questions.
        mode = "0700";
      };

      outputs.services.${config.serviceName} =
        let
          mergedGlobalSettings = {
            "daemonize" = false;
            "error_log" = "/proc/self/fd/2";
          }
          // config.globalSettings;
          cfgFile = pkgs.writeText "phpfpm-${name}.conf" ''
            [global]
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "${n} = ${toStr v}") mergedGlobalSettings)}

            [${name}]
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "${n} = ${toStr v}") config.extraConfig)}
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "env[${n}] = ${toStr v}") config.phpEnv)}
          '';
          iniFile =
            pkgs.runCommand "php.ini"
              {
                inherit (config) phpOptions;
                preferLocalBuild = true;
                passAsFile = [ "phpOptions" ];
              }
              ''
                cat ${config.package}/etc/php.ini $phpOptionsPath > $out
              '';
        in
        {
          type = "process";
          # No wrapper and no shell. services-flake wraps php-fpm in a
          # writeShellApplication that makes the data directory and resolves
          # it: dirs makes the directory before anything starts, and dataDir
          # is absolute throughout, so the prefix needs no normalizing and
          # the command is php-fpm itself.
          command = "${lib.getExe' config.package "php-fpm"} -p ${config.dataDir} -y ${cfgFile} -c ${iniFile}";
          # services-flake asks process-compose for restart = "on_failure" with
          # at most 5 restarts. dinix.critical = false is the nearest thing:
          # boot waits for the service rather than depending on it, so it may
          # die and come back without stopping the container. See redis.nix
          # for the long form of this note.
          dinix.critical = lib.mkDefault false;
        };
    };
  }
)
