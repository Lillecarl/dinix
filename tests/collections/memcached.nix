# A collection: the dinix configuration under test, plus what to ask the
# running container. dev.nix turns this into an image, a guest and a test.
#
# This is the whole of what a service port writes for its test. See PORTING.md.
{ pkgs, config, ... }:
let
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
in
{
  memcached.main.enable = true;

  # memcached refuses to run as root, and the container runs as root. dinit's
  # run-as changes user before exec, so the server never sees root at all —
  # which also means no -u. nobody is in the user database dinix writes, and
  # dinit resolves the name against the passwd and group files the container
  # mounts a file at a time. run-as is a dinit setting, so it goes on the
  # rendered service rather than on the memcached instance.
  services.memcached-main.run-as = "nobody";

  # A second instance on its own port. Two of them under the same key is what
  # catches instances sharing state, as in the redis collection.
  memcached.alt = {
    enable = true;
    port = 11311;
  };
  services.memcached-alt.run-as = "nobody";

  collection = {
    packages = [
      pkgs.bash
      pkgs.netcat
    ];

    checks = [
      {
        name = "memcached answers on its TCP port";
        command = ask config.memcached.main.port "version";
        expect = "VERSION";
      }
      {
        name = "a value writes to the first instance";
        command = ask config.memcached.main.port "set dinix 0 0 9\\r\\nfrom-main";
        expect = "STORED";
      }
      {
        name = "and another under the same key to the second";
        command = ask config.memcached.alt.port "set dinix 0 0 8\\r\\nfrom-alt";
        expect = "STORED";
      }
      {
        # Distinct values rather than a count: from-main reading back on the
        # main port proves the instances keep separate data, which a count of
        # keys would not.
        name = "and the two keep separate data";
        command = ask config.memcached.main.port "get dinix";
        expect = "from-main";
      }
    ];
  };
}
