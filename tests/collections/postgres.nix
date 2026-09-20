# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# postgres is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module, and `initdb` is a sub-service
# of it. See services/postgres.nix and PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  postgresService = lib.modules.importApply ../../services/postgres.nix {
    inherit (pkgs) postgresql;
    dinix-unless = config.unlessPackage;
  };

  main = config.system.services.postgres-main.postgres;

  psql = "${main.package}/bin/psql";

  # Every check reaches the cluster the same way: over the socket, as the
  # superuser initdb made, with the tuple-only unaligned output a substring
  # match can be sure of.
  query =
    statement: "${psql} -h ${main.socketDir} -U ${main.superuser} -d postgres -tAc \"${statement}\"";

  # The cluster belongs to whoever runs the server, and initdb will not touch a
  # PGDATA it does not own. 65534 twice is users.nobody in users.nix, which is
  # only a default: a configuration with its own nobody must say so here as
  # well. An unprivileged dinix-init cannot chown, but it stats first and skips
  # what already matches, so this holds in every mode.
  ownedByNobody = {
    uid = 65534;
    gid = 65534;
  };

  # postgres refuses to run as root and says so: "execution of PostgreSQL by a
  # user with administrative permissions is not permitted". So does initdb.
  # dinit's run-as changes user before exec, so neither ever sees root. Only a
  # privileged dinit sets it; an unprivileged one cannot change user at all,
  # and there whoever started dinit is already the account.
  runAsNobody = lib.mkIf config.privileged "nobody";
in
{
  system.services.postgres-main = {
    imports = [ postgresService ];

    dinit.service.run-as = runAsNobody;
    services.init.dinit.service.run-as = runAsNobody;

    dinit.dirs = lib.genAttrs [
      main.dataDir
      main.pgData
      main.socketDir
    ] (_: ownedByNobody);
  };

  collection = {
    writable = [ main.dataDir ];

    # initdb needs a shell, which nothing else in a dinix image does. It runs
    # `"<bindir>/postgres" -V` through popen to check the server it is about to
    # initialise, and popen is glibc running /bin/sh -c. Without one it fails
    # with `could not execute command … No such file or directory`, which names
    # postgres rather than the shell and sends the reader the wrong way.
    # Measured: the vm modes pass without this because a NixOS guest has
    # /bin/sh, and only the containers fail.
    packages = [ pkgs.busybox ];

    checks = [
      {
        name = "the cluster answers a query over its socket";
        command = query "select 1";
        expect = "1";
      }
      {
        # initdb ran with --username, and nothing else created this role.
        name = "initdb made the superuser the module named";
        command = query "select current_user";
        expect = main.superuser;
      }
      {
        # The settings reached postgres as -c arguments rather than through a
        # postgresql.conf, which is the part of this port that could silently
        # do nothing: a wrong name is ignored rather than refused.
        name = "a setting given on the command line took effect";
        command = query "show port";
        expect = toString main.port;
      }
      {
        # The file configData wrote, at the place dinix chose for it. The
        # module names it through `configData."pg_hba.conf".path`, which holds
        # a marker until the configuration directory is built, so the check
        # asks for the tail of the path rather than the whole of it.
        name = "and the generated pg_hba is the one in use";
        command = query "show hba_file";
        expect = "/system-services/postgres-main/pg_hba.conf";
      }
      {
        name = "a table written now reads back";
        command = query "create table dinix (word text); insert into dinix values ('ported'); select word from dinix";
        expect = "ported";
      }
    ];
  };
}
