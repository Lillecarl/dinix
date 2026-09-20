# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
# See PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  instance = config.postgres.main;
  psql = "${instance.package}/bin/psql";
  # Every check reaches the cluster the same way: over the socket, as the
  # superuser initdb made, with the tuple-only unaligned output a substring
  # match can be sure of.
  query =
    statement:
    "${psql} -h ${instance.socketDir} -U ${instance.superuser} -d postgres -tAc \"${statement}\"";
in
{
  postgres.main.enable = true;

  # postgres refuses to run as root and says so: "execution of PostgreSQL by a
  # user with administrative permissions is not permitted". So does initdb.
  # dinit's run-as changes user before exec, so neither ever sees root. Only
  # a privileged dinit sets it; an unprivileged one cannot change user at all,
  # and there whoever started dinit is already the account.
  services.postgres-main.run-as = lib.mkIf config.privileged "nobody";
  services.postgres-main-init.run-as = lib.mkIf config.privileged "nobody";

  # The cluster belongs to whoever runs the server, and initdb will not touch
  # a PGDATA it does not own. 65534 twice is users.nobody in users.nix, which
  # is only a default: a configuration with its own nobody must say so here as
  # well. An unprivileged dinix-init cannot chown, but it stats first and skips
  # what already matches, so this holds in every mode.
  dirs =
    lib.genAttrs
      [
        instance.dataDir
        instance.pgData
        instance.socketDir
      ]
      (_: {
        uid = 65534;
        gid = 65534;
      });

  collection = {
    writable = [ instance.dataDir ];

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
        expect = instance.superuser;
      }
      {
        # The settings reached postgres as -c arguments rather than through a
        # postgresql.conf, which is the part of this port that could silently
        # do nothing: a wrong name is ignored rather than refused.
        name = "a setting given on the command line took effect";
        command = query "show port";
        expect = toString instance.port;
      }
      {
        name = "and the generated pg_hba is the one in use";
        command = query "show hba_file";
        expect = "${instance.hbaConfFile}";
      }
      {
        name = "a table written now reads back";
        command = query "create table dinix (word text); insert into dinix values ('ported'); select word from dinix";
        expect = "ported";
      }
    ];
  };
}
