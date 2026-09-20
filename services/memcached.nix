# memcached, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/memcached.nix, which is
# Apache-2.0 and itself based on devenv's module. See services/redis.nix for
# the shape and PORTING.md for what changes on the way across.
{ memcached }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.memcached;
in
{
  _class = "service";

  options.memcached = {
    package = mkOption {
      type = types.package;
      default = memcached;
      defaultText = lib.literalMD "the memcached given to this module";
      description = "The memcached package to run.";
    };

    bind = mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = ''
        The address to listen on, or null for every interface.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 11211;
      description = "The TCP port to accept connections on.";
    };

    startArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--memory-limit=256" ];
      description = ''
        Extra arguments for `memcached`.

        One argument per element: a service manager that takes a command line
        rather than an argument vector splits on whitespace, so `--memory-limit
        256` as one string would arrive as one argument.
      '';
    };
  };

  config = {
    # memcached keeps nothing on disk, so it asks for no directory and
    # services-flake gives it no start script either.
    process.argv = [
      (lib.getExe' cfg.package "memcached")
      "--port=${toString cfg.port}"
    ]
    ++ lib.optional (cfg.bind != null) "--listen=${cfg.bind}"
    ++ cfg.startArgs;
  }
  // lib.optionalAttrs (options ? dinit) {
    # services-flake asks process-compose to restart on failure at most five
    # times. See services/redis.nix for what this means.
    dinit.service.dinix.critical = lib.mkDefault false;
  };

  meta.maintainers = [ ];
}
