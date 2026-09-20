# redis, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/redis.nix, which is
# Apache-2.0 and itself based on devenv's module. What a modular service adds
# is that this says what to run without saying who runs it, so the same module
# works under dinit, under systemd and under finit.
#
#     system.services.redis = {
#       imports = [ ./services/redis.nix ];
#       redis.port = 6379;
#     };
#
# Two conventions the interface asks for, and both are worth keeping:
#
#   - No `pkgs` module argument. A dependency arrives through `importApply`
#     closure or as an option the caller fills, so this module is not tied to
#     one nixpkgs.
#   - Anything a particular service manager needs goes behind
#     `lib.optionalAttrs (options ? <manager>)`, so the module still evaluates
#     where that manager is absent.
{ redis }:

{
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.redis;

  # Not `dir` and not `unixsocket`: redis reads this file itself, and the
  # state directory is a template the service manager expands. A path belongs
  # on the command line, where every manager substitutes. See PORTING.md.
  configFile = builtins.toFile "redis.conf" ''
    port ${toString cfg.port}
    ${lib.optionalString (cfg.bind != null) "bind ${cfg.bind}"}
    ${lib.optionalString (cfg.unixSocket != null) "unixsocketperm ${toString cfg.unixSocketPerm}"}
    ${cfg.extraConfig}
  '';
in
{
  _class = "service";

  options.redis = {
    package = mkOption {
      type = types.package;
      default = redis;
      defaultText = lib.literalMD "the redis given to this module";
      description = "The redis package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where this instance keeps its data.

        Defaults to the state directory the service manager names, where it
        names one. Nothing portable declares per-service state yet, so a
        manager without that option needs this set.
      '';
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
      default = 6379;
      description = "The TCP port to accept connections on, or 0 for none.";
    };

    unixSocket = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        A socket to listen on as well. A relative path is taken against
        {option}`redis.dataDir`.
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

  config =
    let
      socket =
        if cfg.unixSocket == null || lib.hasPrefix "/" cfg.unixSocket then
          cfg.unixSocket
        else
          "${cfg.dataDir}/${cfg.unixSocket}";
    in
    {
      process.argv = [
        (lib.getExe' cfg.package "redis-server")
        configFile
        "--dir"
        cfg.dataDir
      ]
      ++ lib.optionals (socket != null) [
        "--unixsocket"
        socket
      ];
    }
    // lib.optionalAttrs (options ? dinit) {
      # dinit has no state-directory option of its own, so the default comes
      # from the one dinix adds, and dinix-init makes the directory before any
      # service starts. Under systemd this would be StateDirectory instead.
      redis.dataDir = lib.mkDefault config.dinit.stateDir;
      dinit.dirs.${cfg.dataDir}.mode = "0700";
      # services-flake asks process-compose to restart on failure at most five
      # times. This is the nearest thing: boot waits for the service rather
      # than depending on it, so it may die and come back without stopping the
      # container. Set it true where redis is why the container exists.
      dinit.service.dinix.critical = lib.mkDefault false;
    };

  meta.maintainers = [ ];
}
