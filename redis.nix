# Ported from services-flake, nix/services/redis.nix, which is Apache-2.0 and
# itself based on devenv's module. The options are theirs, option for option.
# See PORTING.md for what changes on the way across.
let
  inherit (import ./service-lib.nix) multiService;
in
multiService "redis" (
  {
    name,
    config,
    pkgs,
    lib,
    ...
  }:
  let
    inherit (lib) mkOption optionalString types;

    # An absolute socket path, since dinix has no working directory to be
    # relative to. services-flake resolves a relative one against dataDir.
    socket =
      if config.unixSocket == null || lib.hasPrefix "/" (toString config.unixSocket) then
        config.unixSocket
      else
        "${config.dataDir}/${config.unixSocket}";

    configFile = pkgs.writeText "redis-${name}.conf" ''
      port ${toString config.port}
      dir ${config.dataDir}
      ${optionalString (config.bind != null) "bind ${config.bind}"}
      ${optionalString (socket != null) "unixsocket ${socket}"}
      ${optionalString (socket != null) "unixsocketperm ${toString config.unixSocketPerm}"}
      ${config.extraConfig}
    '';
  in
  {
    options = {
      package = lib.mkPackageOption pkgs "redis" { };

      bind = mkOption {
        type = types.nullOr types.str;
        default = "127.0.0.1";
        description = ''
          The address to listen on, or null for every interface.

          A container has its own network namespace, so `null` here is not the
          exposure it would be on a host. It is still not the default.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 6379;
        description = "The TCP port to accept connections on, or 0 for none.";
      };

      unixSocket = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          A socket to listen on as well. A relative path is taken against
          {option}`dataDir`.
        '';
      };

      unixSocketPerm = mkOption {
        type = types.int;
        default = 660;
        description = "Octal permissions for that socket.";
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Appended to the generated `redis.conf` verbatim.";
      };
    };

    config = {
      outputs.dirs.${config.dataDir} = {
        mode = "0700";
      };

      outputs.services.${config.serviceName} = {
        type = "process";
        # No wrapper and no shell. services-flake needs a start script to make
        # the data directory first; dinix-init has already made it, and `dir`
        # is in the generated configuration rather than on the command line.
        command = "${lib.getExe' config.package "redis-server"} ${configFile}";
        # services-flake asks process-compose for restart = "on_failure" with
        # at most 5 restarts. dinix.critical = false is the nearest thing: boot
        # waits for the service rather than depending on it, so it may die and
        # come back without stopping the container. Set it to true where redis
        # is the reason the container exists.
        dinix.critical = lib.mkDefault false;
      };
    };
  }
)
