# A collection: the dinix configuration under test, plus what to ask the
# running container. dev.nix turns this into an image, a guest and a test.
#
# This is the whole of what a service port writes for its test. See PORTING.md.
{ pkgs, config, ... }:
{
  redis.main.enable = true;

  # A second instance, listening only on a socket. Two of them is the point of
  # the instance shape, and nothing else here would catch two services writing
  # to the same data directory.
  redis.sock = {
    enable = true;
    port = 0;
    unixSocket = "redis.sock";
  };

  collection = {
    # Where each instance keeps its data. dinix makes these; podman supplies
    # them as tmpfs, so the test also covers dinix-init setting the mode.
    tmpfs = [
      config.redis.main.dataDir
      config.redis.sock.dataDir
    ];

    checks =
      let
        redis-cli = "${pkgs.redis}/bin/redis-cli";
      in
      [
        {
          name = "redis answers on its TCP port";
          command = "${redis-cli} -p ${toString config.redis.main.port} ping";
          expect = "PONG";
        }
        {
          name = "the second instance answers on its socket";
          command = "${redis-cli} -s ${config.redis.sock.dataDir}/redis.sock ping";
          expect = "PONG";
        }
        {
          name = "a value writes to the first instance";
          command = "${redis-cli} -p ${toString config.redis.main.port} set dinix from-main";
          expect = "OK";
        }
        {
          name = "and another under the same key to the second";
          command = "${redis-cli} -s ${config.redis.sock.dataDir}/redis.sock set dinix from-sock";
          expect = "OK";
        }
        {
          # Distinct values rather than a count: redis-cli prints its raw reply
          # when standard output is not a terminal, so "(integer) 0" never
          # arrives and a bare "0" matches too much to mean anything.
          name = "and the two keep separate data";
          command = "${redis-cli} -p ${toString config.redis.main.port} get dinix";
          expect = "from-main";
        }
      ];
  };
}
