# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# redis is authored as a NixOS Modular Service, so it is instantiated the way
# every modular service is — one `system.services` entry per instance, each
# importing the module. See services/redis.nix and PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  redisService = lib.modules.importApply ../../services/redis.nix { inherit (pkgs) redis; };

  main = config.system.services.redis-main.redis;
  sock = config.system.services.redis-sock.redis;
  redis-cli = "${pkgs.redis}/bin/redis-cli";
in
{
  system.services.redis-main = {
    imports = [ redisService ];
  };

  # A second instance, listening only on a socket. Two of them is what catches
  # instances sharing state, and under modular services an instance is just
  # another entry rather than a shape the module has to provide.
  system.services.redis-sock = {
    imports = [ redisService ];
    redis = {
      port = 0;
      unixSocket = "redis.sock";
    };
  };

  collection = {
    writable = [
      main.dataDir
      sock.dataDir
    ];

    checks = [
      {
        name = "redis answers on its TCP port";
        command = "${redis-cli} -p ${toString main.port} ping";
        expect = "PONG";
      }
      {
        name = "the second instance answers on its socket";
        command = "${redis-cli} -s ${sock.dataDir}/redis.sock ping";
        expect = "PONG";
      }
      {
        name = "a value writes to the first instance";
        command = "${redis-cli} -p ${toString main.port} set dinix from-main";
        expect = "OK";
      }
      {
        name = "and another under the same key to the second";
        command = "${redis-cli} -s ${sock.dataDir}/redis.sock set dinix from-sock";
        expect = "OK";
      }
      {
        # Distinct values rather than a count: redis-cli prints its raw reply
        # when standard output is not a terminal, so "(integer) 0" never
        # arrives and a bare "0" matches too much to mean anything.
        name = "and the two keep separate data";
        command = "${redis-cli} -p ${toString main.port} get dinix";
        expect = "from-main";
      }
    ];
  };
}
