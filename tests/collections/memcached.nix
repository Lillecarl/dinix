# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# memcached is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/memcached.nix and
# PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  memcachedService = lib.modules.importApply ../../services/memcached.nix {
    inherit (pkgs) memcached;
  };

  main = config.system.services.memcached-main.memcached;
  alt = config.system.services.memcached-alt.memcached;

  # memcached ships no client, and the image holds only what the service
  # commands reference. The checks pipe a request into nc, and a pipe takes a
  # shell — named by absolute store path, since the image has no PATH and no
  # /bin/sh. Both go to the container through collection.packages.
  bash = "${pkgs.bash}/bin/bash";
  nc = "${pkgs.netcat}/bin/nc";

  # The memcached text protocol, a request at a time: `printf` turns the
  # escapes into CRLF, nc carries the exchange, and `quit` makes the server
  # close the connection so nc exits on its own.
  ask =
    port: request:
    "${bash} -c \"printf '${request}\\r\\nquit\\r\\n' | ${nc} -w 2 127.0.0.1 ${toString port}\"";

  # memcached refuses to run as root, and both ways out are used. Where dinit
  # is root, run-as changes user before exec so the server never sees root.
  # Everywhere else memcached's own -u drops privilege after startup, which
  # needs root to begin with and is a no-op as nobody, where it resolves and
  # re-applies itself. Every account resolves: dinix's user database in the
  # containers, the guest's own in the vm modes.
  #
  # Two elements, not one string. A service manager that takes a command line
  # quotes each argument, so `-u nobody` as one element would reach memcached
  # as a user called " nobody". It worked before only because the old
  # rendering joined the arguments and let dinit split them again.
  dropPrivilege = [
    "-u"
    "nobody"
  ];
in
{
  system.services.memcached-main = {
    imports = [ memcachedService ];
    memcached.startArgs = dropPrivilege;
    dinit.service.run-as = lib.mkIf config.privileged "nobody";
  };

  # A second instance on its own port. Two of them under the same key is what
  # catches instances sharing state, as in the redis collection.
  system.services.memcached-alt = {
    imports = [ memcachedService ];
    memcached.port = 11311;
    memcached.startArgs = dropPrivilege;
    dinit.service.run-as = lib.mkIf config.privileged "nobody";
  };

  collection = {
    packages = [
      pkgs.bash
      pkgs.netcat
    ];

    checks = [
      {
        name = "memcached answers on its TCP port";
        command = ask main.port "version";
        expect = "VERSION";
      }
      {
        name = "a value writes to the first instance";
        command = ask main.port "set dinix 0 0 9\\r\\nfrom-main";
        expect = "STORED";
      }
      {
        name = "and another under the same key to the second";
        command = ask alt.port "set dinix 0 0 8\\r\\nfrom-alt";
        expect = "STORED";
      }
      {
        # Distinct values rather than a count: from-main reading back on the
        # main port proves the instances keep separate data, which a count of
        # keys would not.
        name = "and the two keep separate data";
        command = ask main.port "get dinix";
        expect = "from-main";
      }
    ];
  };
}
