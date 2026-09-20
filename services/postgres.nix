# postgres, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/postgres/default.nix, which
# is MIT and itself based on devenv's Apache-2.0 module. See services/redis.nix for
# the shape and PORTING.md for what changes on the way across.
#
# `initdb` runs as a sub-service, which is what the modular interface offers
# for a process that belongs to another. It creates no dependency by itself —
# the manual is explicit about that — so the order is stated where the manager
# is known.
{ postgresql, dinix-unless }:

{
  config,
  options,
  name,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.postgres;

  render =
    value:
    if value == true then
      "on"
    else if value == false then
      "off"
    else
      toString value;

  # A setting reaches postgres as `-c name=value` on the command line rather
  # than through a postgresql.conf. A service manager substitutes a command
  # line and postgres does not substitute its own configuration, so a file
  # would have to hold the state directory literally. It also saves copying a
  # file into PGDATA at startup, which is what services-flake needs a shell
  # for.
  settingArgs = lib.concatLists (
    lib.mapAttrsToList (setting: value: [
      "-c"
      "${setting}=${render value}"
    ]) cfg.settings
  );

  defaultHbaConf = [
    {
      type = "local";
      database = "all";
      user = "all";
      address = "";
      method = "trust";
    }
    {
      type = "host";
      database = "all";
      user = "all";
      address = "127.0.0.1/32";
      method = "trust";
    }
    {
      type = "host";
      database = "all";
      user = "all";
      address = "::1/128";
      method = "trust";
    }
  ];
in
{
  _class = "service";

  options.postgres = {
    package = mkOption {
      type = types.package;
      default = postgresql;
      defaultText = lib.literalMD "the postgresql given to this module";
      description = "Which postgresql to run.";
      apply =
        postgresPkg:
        if cfg.extensions == null then
          postgresPkg
        else if postgresPkg ? withPackages then
          postgresPkg.withPackages cfg.extensions
        else
          throw ''
            The postgres.extensions of ${name} is set but its postgres.package has
            no withPackages attribute. It probably already has extensions added.
          '';
    };

    extensions = mkOption {
      type = types.nullOr (types.functionTo (types.listOf types.package));
      default = null;
      example = lib.literalExpression "extensions: [ extensions.postgis ]";
      description = "Extensions to add to {option}`postgres.package`, as `withPackages` takes them.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Everything this instance keeps: the cluster and the socket beside it.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir` for why a manager without that
        option needs this set.
      '';
    };

    pgData = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/data";
      readOnly = true;
      description = ''
        PGDATA: the cluster itself.

        **A subdirectory of {option}`postgres.dataDir`, which services-flake
        uses directly.** `initdb` refuses a directory that is not empty, and
        the socket directory has to live somewhere the same volume provides, so
        one of them has to move. Moving the cluster keeps `dataDir` meaning
        what it means for every other service: everything this instance keeps.
      '';
    };

    socketDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/run";
      description = ''
        Where the Unix socket goes, or the empty string for no socket.

        services-flake defaults this to no socket, and so to TCP only. A socket
        is the default here because it is what a check and a neighbouring
        service in the same container use, and it costs no port.
      '';
    };

    listen_addresses = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Which addresses to accept TCP connections on, or the empty string for
        none. A container has its own network namespace, so `*` here is not the
        exposure it would be on a host. It is still not the default.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5432;
      description = "The TCP port to accept connections on.";
    };

    superuser = mkOption {
      type = types.str;
      default = "postgres";
      description = ''
        The superuser role `initdb` creates.

        A name, not an account: nothing looks it up in the user database, so it
        need not match whoever the service runs as. services-flake defaults to
        `$USER`, which a container has no answer for.
      '';
    };

    initdbArgs = mkOption {
      type = types.listOf types.str;
      default = [
        "--locale=C"
        "--encoding=UTF8"
      ];
      example = [ "--data-checksums" ];
      description = ''
        Extra arguments for `initdb`, which runs once.

        One argument per element: a service manager that takes a command line
        rather than an argument vector splits on whitespace, so `--locale C` as
        one string would arrive as one argument.
      '';
    };

    hbaConf = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            type = mkOption { type = types.str; };
            database = mkOption { type = types.str; };
            user = mkOption { type = types.str; };
            address = mkOption {
              type = types.str;
              default = "";
            };
            method = mkOption { type = types.str; };
          };
        }
      );
      default = [ ];
      description = ''
        Entries appended to the generated `pg_hba.conf`, after the defaults:
        `trust` for local connections and for 127.0.0.1 and ::1.

        Those defaults trust anyone who can reach the socket or the loopback
        address, which in a container is anything already inside it. Replace
        them through {option}`postgres.settings`.`hba_file` where that is not
        what you want.
      '';
      example = [
        {
          type = "host";
          database = "all";
          user = "all";
          address = "0.0.0.0/0";
          method = "scram-sha-256";
        }
      ];
    };

    settings = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.bool
          types.float
          types.int
          types.str
        ]
      );
      default = { };
      description = ''
        `postgresql.conf` settings, one attribute per name. See
        <https://www.postgresql.org/docs/current/config-setting.html>.

        They reach postgres as `-c name=value` arguments rather than through a
        file, so nothing is written into PGDATA at startup. A boolean becomes
        `on` or `off`.

        `unix_socket_directories` is not settable here: it names a path under
        the state directory, which only the command line can carry. Use
        {option}`postgres.socketDir`.
      '';
      example = lib.literalExpression ''
        {
          log_connections = true;
          log_statement = "all";
        }
      '';
    };

    connectionURI = mkOption {
      type = types.functionTo types.str;
      readOnly = true;
      default = { dbName, ... }: "postgres://${cfg.listen_addresses}:${toString cfg.port}/${dbName}";
      description = ''
        A function from `{ dbName }` to a connection URI. Only useful when
        {option}`postgres.listen_addresses` names an address: a socket has no
        URI of this shape.
      '';
    };
  };

  config = lib.mkMerge [
    {
      postgres.settings = {
        listen_addresses = lib.mkDefault cfg.listen_addresses;
        port = lib.mkDefault cfg.port;
        hba_file = lib.mkDefault config.configData."pg_hba.conf".path;
      };

      # A store path, so postgres never rewrites it.
      configData."pg_hba.conf".text =
        "# Generated by dinix.\n# TYPE\tDATABASE\tUSER\tADDRESS\tMETHOD\n"
        + lib.concatMapStrings (
          entry: "${entry.type}\t${entry.database}\t${entry.user}\t${entry.address}\t${entry.method}\n"
        ) (defaultHbaConf ++ cfg.hbaConf);

      # Once, and without a shell. initdb exits 1 on a directory that is not
      # empty, so running it every start would fail every start after the
      # first; dinix-unless runs it only while PG_VERSION is absent.
      services.init.process.argv = [
        (lib.getExe dinix-unless)
        "${cfg.pgData}/PG_VERSION"
        (lib.getExe' cfg.package "initdb")
        "--pgdata"
        cfg.pgData
        "--username"
        cfg.superuser
      ]
      ++ cfg.initdbArgs;

      # No wrapper and no shell. services-flake needs one to export PGDATA,
      # resolve it and copy a configuration in; every one of those is an
      # argument here, and the service manager substitutes the state directory
      # into each.
      process.argv = [
        (lib.getExe' cfg.package "postgres")
        "-D"
        cfg.pgData
      ]
      ++ lib.optionals (cfg.socketDir != "") [
        "-k"
        cfg.socketDir
      ]
      ++ settingArgs;
    }

    (lib.optionalAttrs (options ? dinit) {
      postgres.dataDir = lib.mkDefault config.dinit.stateDir;

      dinit.dirs = {
        # The instance directory holds the cluster and the socket beside it.
        ${cfg.dataDir}.mode = "0755";
        # initdb insists PGDATA is 0700 or 0750, and makes it 0700 itself. An
        # empty directory is fine; a populated one is what it refuses.
        ${cfg.pgData}.mode = "0700";
      }
      // lib.optionalAttrs (cfg.socketDir != "") {
        ${cfg.socketDir}.mode = "0755";
      };

      dinit.service = {
        # What dinix calls a sub-service, which is the service's own name and
        # the sub-service's joined by a dash.
        depends-on = [ "${name}-init" ];
        # SIGINT is postgres's fast shutdown: it rolls back and disconnects
        # rather than waiting for clients to leave, which SIGTERM does.
        # services-flake asks process-compose for the same with
        # shutdown.signal = 2. Without it a container waits out its grace
        # period whenever anything is connected.
        term-signal = "INT";
        dinix.critical = lib.mkDefault false;
      };

      services.init.dinit.service = {
        type = "scripted";
        dinix.log = "console";
      };
    })
  ];

  meta.maintainers = [ ];
}
