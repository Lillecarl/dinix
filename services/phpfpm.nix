# php-fpm, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/phpfpm.nix, which is MIT.
# See services/redis.nix for the shape and PORTING.md for what changes on the
# way across.
#
# nixpkgs ships a php-fpm modular service of its own, as `php.services.default`
# in pkgs/development/interpreters/php/service.nix. The `php-upstream`
# collection runs that one unmodified. This module exists beside it because two
# things it offers are not expressible there yet: a `php.ini` of one's own, and
# a pool socket under a state directory the service manager names. Its pool
# configuration is a generated file, and a path inside a generated file is
# fixed when it is generated. See issue #15.
{ php, runCommand }:

{
  config,
  options,
  name,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.phpfpm;

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

  settings = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: v: "${n} = ${toStr v}") cfg.extraConfig
  );
  globals = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: v: "${n} = ${toStr v}") (
      {
        "daemonize" = false;
        "error_log" = "/proc/self/fd/2";
      }
      // cfg.globalSettings
    )
  );
  environment = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: v: "env[${n}] = ${toStr v}") cfg.phpEnv
  );
in
{
  _class = "service";

  options.phpfpm = {
    package = mkOption {
      type = types.package;
      default = php;
      defaultText = lib.literalMD "the php given to this module";
      description = "The PHP package whose `php-fpm` runs this pool.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        The prefix php-fpm runs under, and so where a relative
        {option}`phpfpm.listen` puts its socket.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir` for why a manager without that
        option needs this set.
      '';
    };

    listen = mkOption {
      type = types.either types.port types.str;
      default = "phpfpm.sock";
      description = ''
        The address on which to accept FastCGI requests.

        A path that is not absolute is taken against {option}`phpfpm.dataDir`,
        which is what php-fpm's own prefix does with it.
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

  # mkMerge, not `//`, because both halves set `phpfpm`: a shallow merge would
  # drop the pool defaults below in favour of the one attribute the dinit half
  # sets, and the pool would start with no listen address.
  config = lib.mkMerge [
    {
      phpfpm.extraConfig.listen = lib.mkDefault cfg.listen;

      # A php-fpm master running as root refuses to start without a pool user:
      # "[pool proto] user has not been defined", then "FPM initialization
      # failed", exit 78. It says this before any request, so the service looks
      # started and the first check is what finds it. Running unprivileged it
      # ignores both directives with a warning, so one default serves every mode.
      # Override them like any other pool directive.
      phpfpm.extraConfig.user = lib.mkDefault "nobody";
      phpfpm.extraConfig.group = lib.mkDefault "nogroup";

      configData."phpfpm.conf".text = ''
        [global]
        ${globals}

        [${name}]
        ${settings}
        ${environment}
      '';

      # php.ini is the package's own with the pool's options after it, which is
      # what services-flake does. It takes a build rather than a `text`, because
      # the first half is a file inside the package.
      configData."php.ini".source =
        runCommand "php.ini"
          {
            inherit (cfg) phpOptions;
            preferLocalBuild = true;
            passAsFile = [ "phpOptions" ];
          }
          ''
            cat ${cfg.package}/etc/php.ini $phpOptionsPath > $out
          '';

      # No wrapper and no shell. services-flake wraps php-fpm in a
      # writeShellApplication that makes the data directory and resolves it: a
      # directory made before anything starts, and an absolute dataDir, leave
      # php-fpm itself as the command.
      process.argv = [
        (lib.getExe' cfg.package "php-fpm")
        "-p"
        cfg.dataDir
        "-y"
        config.configData."phpfpm.conf".path
        "-c"
        config.configData."php.ini".path
      ];
    }
    (lib.optionalAttrs (options ? dinit) {
      phpfpm.dataDir = lib.mkDefault config.dinit.stateDir;
      # The pool's socket lives here when `listen` names one, so whoever the
      # master runs as must own the directory. The collection says who that is.
      dinit.dirs.${cfg.dataDir}.mode = "0700";
      # services-flake asks process-compose for restart = "on_failure" with at
      # most 5 restarts. See services/redis.nix for what this means.
      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
