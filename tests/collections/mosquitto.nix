# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# Mosquitto is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/mosquitto.nix
# and PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  mosquittoService = lib.modules.importApply ../../services/mosquitto.nix {
    inherit (pkgs) mosquitto;
  };

  main = config.system.services.mosquitto-main.mosquitto;
  alt = config.system.services.mosquitto-alt.mosquitto;

  bash = "${pkgs.bash}/bin/bash";
  pub = "${pkgs.mosquitto}/bin/mosquitto_pub";
  sub = "${pkgs.mosquitto}/bin/mosquitto_sub";

  # Retained, so one check publishes and a later one reads it back without a
  # subscriber waiting in the background.
  publish =
    instance: value:
    "${pub} -h 127.0.0.1 -p ${toString instance.port} -t dinix/marker -m ${value} -r";

  read =
    instance: "${sub} -h 127.0.0.1 -p ${toString instance.port} -t dinix/marker -C 1 -W 5";
in
{
  system.services.mosquitto-main = {
    imports = [ mosquittoService ];
    mosquitto = {
      persistence = true;
      # 1s, not the default 1800s: the check below waits for the file, and a
      # check gives up after 60s.
      extraConfig = "autosave_interval 1";
    };
  };

  # A second instance on its own port, keeping nothing. Two of them is what
  # catches instances sharing state.
  system.services.mosquitto-alt = {
    imports = [ mosquittoService ];
    mosquitto.port = 1884;
  };

  collection = {
    packages = [
      pkgs.bash
      pkgs.mosquitto
    ];

    writable = [ main.dataDir ];

    checks = [
      {
        name = "mosquitto takes a retained message";
        command = publish main "from-main";
        expect = "";
      }
      {
        name = "and gives it back";
        command = read main;
        expect = "from-main";
      }
      {
        name = "the second instance takes its own";
        command = publish alt "from-alt";
        expect = "";
      }
      {
        # Distinct values rather than a count: each broker holding only its
        # own is what says the two are separate.
        name = "and the two keep separate messages";
        command = read alt;
        expect = "from-alt";
      }
      {
        # The persistent broker writes mosquitto.db into its working
        # directory, which is the only way a state path reaches mosquitto.
        # See services/mosquitto.nix.
        name = "the persistent broker writes its database";
        command = "${bash} -c ${lib.escapeShellArg "test -f ${main.dataDir}/mosquitto.db && echo dinix-db-present"}";
        expect = "dinix-db-present";
      }
    ];
  };
}
