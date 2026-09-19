# Ported from services-flake, nix/services/memcached.nix, which is Apache-2.0
# and itself based on devenv's module. The options are theirs, option for
# option. See PORTING.md for what changes on the way across.
let
  inherit (import ./service-lib.nix) multiService;
in
multiService "memcached" (
  {
    config,
    pkgs,
    lib,
    ...
  }:
  let
    inherit (lib) mkOption optional types;
  in
  {
    options = {
      package = lib.mkPackageOption pkgs "memcached" { };

      bind = mkOption {
        type = types.nullOr types.str;
        default = "127.0.0.1";
        description = ''
          The IP interface to bind to, or null for every interface.

          A container has its own network namespace, so `null` here is not the
          exposure it would be on a host. It is still not the default.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 11211;
        description = ''
          The TCP port to accept connections on, or 0 for none.
        '';
      };

      startArgs = mkOption {
        type = types.listOf types.lines;
        default = [ ];
        description = ''
          Additional arguments passed to `memcached` during startup.
        '';
      };
    };

    config = {
      # Nothing in `dirs`: memcached keeps no data on disk, and services-flake
      # has no start script to make a directory either. `dataDir` exists and is
      # unused, exactly as there.
      outputs.services.${config.serviceName} = {
        type = "process";
        # No wrapper and no shell. services-flake builds this command as one
        # interpolated string, where a null `bind` cannot survive: a port that
        # keeps the option has to drop the flag instead.
        command = toString (
          [
            (lib.getExe' config.package "memcached")
            "--port=${toString config.port}"
          ]
          ++ optional (config.bind != null) "--listen=${config.bind}"
          ++ config.startArgs
        );
        # services-flake asks process-compose for restart = "on_failure" with
        # at most 5 restarts. dinix.critical = false is the nearest thing: boot
        # waits for the service rather than depending on it, so it may die and
        # come back without stopping the container. See redis.nix for the long
        # form of this note.
        dinix.critical = lib.mkDefault false;
      };
    };
  }
)
