# MariaDB, as a NixOS Modular Service.
#
# Options ported from services-flake's nix/services/mysql/default.nix, which is
# MIT, and devenv's src/modules/services/mysql.nix, which is Apache-2.0. See
# services/redis.nix for the shape and PORTING.md for what changes on the way
# across.
#
# `mariadb-install-db` runs as a sub-service, the way `initdb` does in
# services/postgres.nix. A sub-service creates no dependency by itself, so the
# order is stated where the service manager is known.
{
  mariadb,
  coreutils,
  gnused,
  dinix-unless,
}:

{
  config,
  options,
  name,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.mysql;

  quote = value: "'${lib.replaceStrings [ "'" ] [ "''" ] value}'";

  initSql =
    lib.concatMapStrings (database: "CREATE DATABASE IF NOT EXISTS `${database.name}`;\n") cfg.initialDatabases
    + lib.concatMapStrings (
      user:
      "CREATE USER IF NOT EXISTS ${quote user.name}@${quote user.host}"
      + lib.optionalString (user.password != null) " IDENTIFIED BY ${quote user.password}"
      + ";\n"
      + lib.concatStrings (
        lib.mapAttrsToList (
          target: permission: "GRANT ${permission} ON ${target} TO ${quote user.name}@${quote user.host};\n"
        ) user.ensurePermissions
      )
    ) cfg.ensureUsers
    + cfg.initScript;
in
{
  _class = "service";

  options.mysql = {
    package = mkOption {
      type = types.package;
      default = mariadb;
      defaultText = lib.literalMD "the mariadb given to this module";
      description = ''
        Which MariaDB to run. Oracle MySQL does not work here: this module
        initialises a data directory with `mariadb-install-db`, and MySQL's
        equivalent is `mysqld --initialize-insecure` instead.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Everything this instance keeps: the data directory and the socket
        beside it.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir` for why a manager without that
        option needs this set.
      '';
    };

    mysqlData = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/data";
      readOnly = true;
      description = ''
        The data directory itself, a subdirectory of {option}`mysql.dataDir`.

        The socket has to live somewhere the same volume provides, so one of
        the two has to move. Moving the data keeps `dataDir` meaning what it
        means for every other service: everything this instance keeps.
      '';
    };

    socketDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/run";
      description = "Where the Unix socket goes.";
    };

    tmpDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/tmp";
      description = ''
        Where temporary tables go, as `--tmpdir`.

        Per instance, and not `/tmp`, because two instances there collide.
        Measured: two `mariadb-install-db` bootstraps started together in the
        same container both reached for `/tmp/#sql-temptable-38-1-4`, and one
        of them died with `ERROR: 1051 Unknown table 'mysql.tmp_user_sys'`.
        The name carries a thread id, which two processes share.
      '';
    };

    socket = mkOption {
      type = types.str;
      default = "${cfg.socketDir}/mysql.sock";
      readOnly = true;
      description = "The Unix socket itself. What a client passes to `--socket`.";
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        The address to accept TCP connections on. A container has its own
        network namespace, so `0.0.0.0` here is not the exposure it would be on
        a host. It is still not the default.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 3306;
      description = "The TCP port to accept connections on.";
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = "root";
      description = ''
        The account `mariadbd` changes to, as `--user`, or null for no such
        argument.

        Measured, and the reason this defaults to a value rather than to null:
        `mariadbd` refuses to start as root without it — "Please consult the
        Knowledge Base to find out how to run mysqld as root!", and it exits.
        Started by anyone else, `--user` prints "One can only use the --user
        switch if running as root" and carries on. So `root` is the one value
        that works whether or not the service manager is root, which is what
        lets one service description run in a container, uncontained and under
        systemd alike.

        `mariadb-install-db` takes no `--user` here, and needs none: its
        bootstrap server has no such refusal, and the argument would make it
        chown the data directory, which fails for anyone but root.
      '';
    };

    settings = mkOption {
      type = types.attrsOf (
        types.attrsOf (
          types.oneOf [
            types.bool
            types.int
            types.str
            (types.listOf types.str)
          ]
        )
      );
      default = { };
      description = ''
        `my.cnf`, one attribute per section. It reaches both `mariadbd` and
        `mariadb-install-db` as `--defaults-file`, so nothing outside it is
        read — not `/etc/my.cnf`, not `~/.my.cnf`.

        The data directory, the socket and the address are not settable here:
        each names a path or a port the command line carries, so that the
        service manager substitutes them. Use {option}`mysql.dataDir`,
        {option}`mysql.socketDir`, {option}`mysql.bind` and
        {option}`mysql.port`.
      '';
      example = lib.literalExpression ''
        {
          mysqld = {
            key_buffer_size = "6G";
            plugin-load-add = [ "server_audit" "ed25519=auth_ed25519" ];
          };
          mysqldump.quick = true;
        }
      '';
    };

    initialDatabases = mkOption {
      type = types.listOf (
        types.submodule {
          options.name = mkOption {
            type = types.str;
            description = "The database to create.";
          };
        }
      );
      default = [ ];
      example = [ { name = "dinix"; } ];
      description = ''
        Databases to create, as `CREATE DATABASE IF NOT EXISTS`.

        No schema attribute, which services-flake has: a schema is a file the
        server would have to read at a point nothing here can reach. Put the
        statements in {option}`mysql.initScript` and make them idempotent.
      '';
    };

    ensureUsers = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "The account to create.";
            };

            host = mkOption {
              type = types.str;
              default = "localhost";
              example = "%";
              description = ''
                Where the account may connect from.

                `%` does not cover a local connection. `mariadb-install-db`
                creates an anonymous `'''@'localhost'` account, which is more
                specific, so it matches a connection from 127.0.0.1 first and
                denies it. An account that has to serve both needs a row for
                each.
              '';
            };

            password = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                The password, or null for an account with none.

                **This goes into the store, where everything is world
                readable.** It is here because the source modules have it and a
                development database wants it. A password that matters is
                mounted instead, and set through a statement this module never
                sees.
              '';
            };

            ensurePermissions = mkOption {
              type = types.attrsOf types.str;
              default = { };
              example = {
                "dinix.*" = "ALL PRIVILEGES";
              };
              description = ''
                Grants for the account, as `GRANT <value> ON <name>`.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        Accounts to create, as `CREATE USER IF NOT EXISTS`, with their grants.

        Nothing here removes an account or a grant. Taking one away means
        taking it away in the database as well.
      '';
    };

    initScript = mkOption {
      type = types.lines;
      default = "";
      example = "CREATE TABLE IF NOT EXISTS dinix.t (id INT);";
      description = ''
        SQL appended to the generated init file, after the databases and the
        accounts.

        **It runs at every startup, not once**, because it reaches the server
        as `--init-file`, which is the one way to run a statement without a
        readiness probe and a second process. Every statement has to be
        idempotent. A statement that must run once belongs behind its own
        marker, the way `mariadb-install-db` is.
      '';
    };
  };

  config = lib.mkMerge [
    {
      configData = {
        "my.cnf".text = lib.generators.toINI { listsAsDuplicateKeys = true; } cfg.settings;
        "init.sql".text = initSql;
      };

      # Once, and without a shell. `mariadb-install-db` refuses a data
      # directory that already holds system tables, so running it every start
      # would fail every start after the first.
      #
      # `env` is here because the program is a shell script that calls `sed`,
      # and an image made of store paths has no PATH at all: without one it
      # exits 1 at "sed: command not found". The script's own shebang names
      # store bash, so that much needs nothing.
      services.init.process.argv = [
        (lib.getExe dinix-unless)
        "${cfg.mysqlData}/mysql"
        (lib.getExe' coreutils "env")
        "PATH=${lib.makeBinPath [ coreutils gnused ]}"
        (lib.getExe' cfg.package "mariadb-install-db")
        "--defaults-file=${config.configData."my.cnf".path}"
        "--datadir=${cfg.mysqlData}"
        "--basedir=${cfg.package}"
        # Unrecognised here, so the script hands it to the bootstrap server.
        "--tmpdir=${cfg.tmpDir}"
        # The historical behaviour: a root account with no password, reachable
        # over the socket and over the loopback address. The same trust the
        # postgres port's default `pg_hba.conf` gives, and for the same reason
        # — inside a container that is whoever is already inside it.
        "--auth-root-authentication-method=normal"
      ];

      # --defaults-file first, which mariadbd insists on.
      process.argv = [
        (lib.getExe' cfg.package "mariadbd")
        "--defaults-file=${config.configData."my.cnf".path}"
        "--datadir=${cfg.mysqlData}"
        "--tmpdir=${cfg.tmpDir}"
        "--socket=${cfg.socket}"
        "--bind-address=${cfg.bind}"
        "--port=${toString cfg.port}"
        "--init-file=${config.configData."init.sql".path}"
      ]
      ++ lib.optionals (cfg.user != null) [ "--user=${cfg.user}" ];
    }

    (lib.optionalAttrs (options ? dinit) {
      mysql.dataDir = lib.mkDefault config.dinit.stateDir;

      dinit.dirs = {
        ${cfg.dataDir}.mode = "0755";
        ${cfg.mysqlData}.mode = "0700";
        ${cfg.socketDir}.mode = "0755";
        ${cfg.tmpDir}.mode = "0700";
      };

      dinit.service = {
        depends-on = [ "${name}-init" ];
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
