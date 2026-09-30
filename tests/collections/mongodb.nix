# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# mongodb is authored as a NixOS Modular Service, so it is instantiated the way
# every modular service is — one `system.services` entry per instance, each
# importing the module. See services/mongodb.nix and PORTING.md.
#
# mongodb-ce is unfree, which dev.nix's pkgs allows.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  mongodbService = lib.modules.importApply ../../services/mongodb.nix {
    mongodb = pkgs."mongodb-ce";
  };

  main = config.system.services.mongodb-main.mongodb;

  mongosh = "${pkgs.mongosh}/bin/mongosh";

  # --quiet drops the shell banner, and an eval prints just the value, so a
  # substring match means something.
  eval =
    statement:
    "${mongosh} --quiet --host 127.0.0.1 --port ${toString main.port} --eval '${statement}'";
in
{
  system.services.mongodb-main = {
    imports = [ mongodbService ];
  };

  collection = {
    writable = [ main.dataDir ];

    packages = [ pkgs.mongosh ];

    checks = [
      {
        name = "mongod answers a ping";
        command = eval "db.runCommand({ ping: 1 }).ok";
        expect = "1";
      }
      {
        name = "a document writes and reads back";
        command = eval ''
          db.getSiblingDB("dinix").t.insertOne({ k: "v" });
          db.getSiblingDB("dinix").t.findOne().k
        '';
        expect = "v";
      }
    ];
  };
}
