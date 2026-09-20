# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# MariaDB is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/mysql.nix and
# PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  mysqlService = lib.modules.importApply ../../services/mysql.nix {
    inherit (pkgs) mariadb coreutils gnused;
    dinix-unless = config.unlessPackage;
  };

  main = config.system.services.mysql-main.mysql;
  alt = config.system.services.mysql-alt.mysql;

  mariadb = "${pkgs.mariadb}/bin/mariadb";

  ask =
    instance: statement:
    "${mariadb} --socket=${instance.socket} --user=root --batch --skip-column-names --execute ${lib.escapeShellArg statement}";

  # Two servers in a 2048M guest. The defaults reserve far more than a test
  # needs, and the point here is the service description rather than
  # throughput.
  small.mysqld = {
    innodb_buffer_pool_size = "16M";
    key_buffer_size = "8M";
    performance_schema = 0;
  };

  # Two servers with one tmpdir each, which is what this collection caught:
  # both bootstraps reached for the same file under a shared /tmp and one of
  # them died. See mysql.tmpDir.
  #
  # A row rather than a bare database name: two instances that never notice
  # each other are what this collection is for, and a distinct value proves it
  # where a schema listing would not. REPLACE, because --init-file runs at
  # every startup.
  marker = database: value: ''
    CREATE TABLE IF NOT EXISTS `${database}`.marker (id INT PRIMARY KEY, v VARCHAR(32));
    REPLACE INTO `${database}`.marker VALUES (1, '${value}');
  '';

  appPassword = "dinix-app-password";
in
{
  system.services.mysql-main = {
    imports = [ mysqlService ];
    mysql = {
      settings = small;
      initialDatabases = [ { name = "dinix_main"; } ];
      ensureUsers = [
        {
          name = "dinix_app";
          # `localhost` and not `%`, although the login below is over TCP:
          # MariaDB resolves 127.0.0.1 backwards, and the anonymous
          # `''@'localhost'` account that mariadb-install-db creates is more
          # specific than `%`, so it matches first and denies. Measured —
          # `%` gives "Access denied for user 'dinix_app'@'localhost'".
          host = "localhost";
          password = appPassword;
          ensurePermissions."dinix_main.*" = "ALL PRIVILEGES";
        }
      ];
      initScript = marker "dinix_main" "from-main";
    };
  };

  # A second instance on its own port, with its own data directory.
  system.services.mysql-alt = {
    imports = [ mysqlService ];
    mysql = {
      port = 3307;
      settings = small;
      initialDatabases = [ { name = "dinix_alt"; } ];
      initScript = marker "dinix_alt" "from-alt";
    };
  };

  collection = {
    writable = [
      main.dataDir
      alt.dataDir
    ];

    checks = [
      {
        name = "mysql answers on its socket";
        command = ask main "SELECT 'mysql-main-alive'";
        expect = "mysql-main-alive";
      }
      {
        # The database comes from initialDatabases and the row from
        # initScript, so one answer covers both halves of the init file.
        name = "the init file made a database and filled it";
        command = ask main "SELECT v FROM dinix_main.marker";
        expect = "from-main";
      }
      {
        name = "and the second instance keeps its own";
        command = ask alt "SELECT v FROM dinix_alt.marker";
        expect = "from-alt";
      }
      {
        # Over TCP and as the ensured account, which is the other half of the
        # init file: the socket check above is always root.
        name = "the ensured account logs in over TCP";
        command = "${mariadb} --host=127.0.0.1 --port=${toString main.port} --user=dinix_app --password=${appPassword} --batch --skip-column-names --execute ${lib.escapeShellArg "SELECT 'as-dinix-app'"}";
        expect = "as-dinix-app";
      }
    ];
  };
}
