# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# nats-server is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/nats.nix and
# PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  natsService = lib.modules.importApply ../../services/nats.nix {
    inherit (pkgs) nats-server;
  };

  main = config.system.services.nats-main.nats;
  js = config.system.services.nats-js.nats;

  # nats-server ships no client. natscli is the official one and needs no
  # environment: measured with `env -i`, which is what the checks get.
  nats = "${pkgs.natscli}/bin/nats";

  ask = instance: args: "${nats} --server 127.0.0.1:${toString instance.settings.port} ${args}";
in
{
  system.services.nats-main = {
    imports = [ natsService ];
  };

  # A second instance, with JetStream. Two of them is what catches instances
  # sharing state, and JetStream is the only part of NATS that writes
  # anything — so this one proves the store directory as well.
  system.services.nats-js = {
    imports = [ natsService ];
    nats = {
      jetstream = true;
      settings = {
        server_name = "dinix-js";
        port = 4333;
        monitor_port = 8333;
      };
    };
  };

  collection = {
    packages = [ pkgs.natscli ];

    writable = [ js.dataDir ];

    checks = [
      {
        name = "nats accepts a connection";
        command = ask main "server check connection";
        expect = "Connection OK";
      }
      {
        name = "and takes a published message";
        command = ask main "pub dinix.test from-main";
        expect = ''Published 9 bytes to "dinix.test"'';
      }
      {
        # A bucket is JetStream, and JetStream is the store directory: the
        # server refuses this when `-js` is absent and fails it when `-sd`
        # names somewhere it cannot write.
        name = "the second instance makes a JetStream bucket";
        command = ask js "kv add dinix-kv";
        expect = "Bucket Name: dinix-kv";
      }
      {
        name = "a value writes to that bucket";
        command = ask js "kv put dinix-kv marker from-jetstream";
        expect = "from-jetstream";
      }
      {
        name = "and reads back out of it";
        command = ask js "kv get dinix-kv marker --raw";
        expect = "from-jetstream";
      }
    ];
  };
}
