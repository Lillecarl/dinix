# garage, as a NixOS Modular Service.
#
# Options ported from devenv's src/modules/services/garage.nix, which is
# Apache-2.0. See services/redis.nix for the shape and PORTING.md for what
# changes on the way across.
#
# Garage reads a TOML file and nothing else: it takes no data-directory flag
# and no environment override for one. So the first service here writes
# `garage.toml` from `$DINIX_STATE_DIR` before it execs `garage server`, and a
# second, scripted service applies the cluster layout once the server answers.
# This is one of the rare ports that needs a shell; see PORTING.md. The scripts
# live in `configData` files rather than on the command line, because a dinit
# service description is line-based and a multi-line `-c` argument would break
# it.
{ garage, bash, coreutils }:

{
  config,
  options,
  name,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.garage;

  cli = lib.getExe cfg.package;
  sleep = lib.getExe' coreutils "sleep";

  # One `garage bucket create` per declared bucket, tolerating "already
  # exists" so a restart is idempotent.
  bucketLines = lib.concatMapStringsSep "\n" (
    bucket: "${cli} -c \"$config\" bucket create ${lib.escapeShellArg bucket} 2>/dev/null || true"
  ) cfg.buckets;

  # The data directory is the state directory dinit expands, and garage will
  # not substitute it, so the TOML is written at startup rather than at build
  # time. `printf` rather than a heredoc so no quoting layer has to agree with
  # another.
  startScript = ''
    set -eu
    dir="${cfg.dataDir}"
    config="$dir/garage.toml"
    {
      printf 'metadata_dir = "%s/meta"\n' "$dir"
      printf 'data_dir = "%s/data"\n' "$dir"
      printf 'db_engine = "sqlite"\n'
      printf 'replication_factor = %s\n' '${toString cfg.replicationFactor}'
      printf 'rpc_bind_addr = "%s:%s"\n' '${cfg.bind}' '${toString cfg.rpcPort}'
      printf 'rpc_public_addr = "%s:%s"\n' '${cfg.bind}' '${toString cfg.rpcPort}'
      printf 'rpc_secret = "%s"\n' '${cfg.rpcSecret}'
      printf '\n[s3_api]\n'
      printf 's3_region = "%s"\n' '${cfg.region}'
      printf 'api_bind_addr = "%s:%s"\n' '${cfg.bind}' '${toString cfg.s3Port}'
      printf '\n[admin]\n'
      printf 'api_bind_addr = "%s:%s"\n' '${cfg.bind}' '${toString cfg.adminPort}'
      printf 'admin_token = "%s"\n' '${cfg.adminToken}'
      printf '%s\n' ${lib.escapeShellArg cfg.extraConfig}
    } > "$config"
    exec ${cli} -c "$config" server
  '';

  # Applies the layout once, then makes the buckets. Garage refuses S3 traffic
  # until a node has a role, so a consumer that wants a bucket needs this to
  # have finished.
  initScript = ''
    set -eu
    dir="${cfg.dataDir}"
    config="$dir/garage.toml"
    until ${cli} -c "$config" status >/dev/null 2>&1; do
      ${sleep} 1
    done
    status=$(${cli} -c "$config" status)
    if [[ "$status" == *"NO ROLE ASSIGNED"* ]]; then
      node=$(${cli} -c "$config" node id)
      node="''${node%%@*}"
      ${cli} -c "$config" layout assign -z dc1 -c 1G "$node"
      ${cli} -c "$config" layout apply --version 1
    fi
    ${bucketLines}
  '';
in
{
  _class = "service";

  options.garage = {
    package = mkOption {
      type = types.package;
      default = garage;
      defaultText = lib.literalMD "the garage given to this module";
      description = "The garage package to run.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Where this instance keeps its metadata and its object data.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "The address all three listeners bind to.";
    };

    rpcPort = mkOption {
      type = types.port;
      default = 3901;
      description = "The port for intra-cluster RPC.";
    };

    s3Port = mkOption {
      type = types.port;
      default = 3900;
      description = "The port for the S3 API.";
    };

    adminPort = mkOption {
      type = types.port;
      default = 3903;
      description = "The port for the admin API.";
    };

    region = mkOption {
      type = types.str;
      default = "garage";
      description = "The region label the S3 API reports.";
    };

    replicationFactor = mkOption {
      type = types.int;
      default = 1;
      description = "The cluster replication factor. A single node uses 1.";
    };

    rpcSecret = mkOption {
      type = types.str;
      default = "0000000000000000000000000000000000000000000000000000000000000000";
      description = ''
        The intra-cluster RPC secret, as 64 hexadecimal characters.

        The default is a placeholder for a single-node development instance.
        Every node of a real cluster needs the same secret.
      '';
    };

    adminToken = mkOption {
      type = types.str;
      default = "devtoken";
      description = ''
        The bearer token for the admin API.

        The default is a placeholder. The admin API can create buckets and
        keys, so a deployment that exposes it needs a real value.
      '';
    };

    buckets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "uploads" ];
      description = "Buckets to make once the layout is applied.";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Appended to the generated `garage.toml` verbatim.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.rpcSecret != "";
          message = "garage.rpcSecret is empty.";
        }
        {
          assertion = cfg.adminToken != "";
          message = "garage.adminToken is empty; the admin API has no usable token.";
        }
      ];

      configData = {
        "garage-start.sh".text = startScript;
        "garage-init.sh".text = initScript;
      };

      process.argv = [
        (lib.getExe' bash "bash")
        config.configData."garage-start.sh".path
      ];
    }

    (lib.optionalAttrs (options ? dinit) {
      garage.dataDir = lib.mkDefault config.dinit.stateDir;

      dinit.dirs = {
        ${cfg.dataDir}.mode = "0755";
        "${cfg.dataDir}/meta".mode = "0700";
        "${cfg.dataDir}/data".mode = "0700";
      };

      # Its own name is `<name>-init`; it waits for the parent rather than the
      # other way round, because the parent cannot serve S3 usefully until
      # this has run.
      services.init = {
        process.argv = [
          (lib.getExe' bash "bash")
          config.configData."garage-init.sh".path
        ];
        dinit.service = {
          type = "scripted";
          dinix.log = "console";
          # Started by boot like any other service, so it is not left with
          # nobody depending on it. `waits-for` orders it after the server it
          # talks to.
          dinix.critical = false;
          waits-for = [ name ];
        };
      };

      dinit.service.dinix.critical = lib.mkDefault false;
    })
  ];

  meta.maintainers = [ ];
}
