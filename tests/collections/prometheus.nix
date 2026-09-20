# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# Prometheus is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/prometheus.nix
# and PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  prometheusService = lib.modules.importApply ../../services/prometheus.nix {
    inherit (pkgs) prometheus;
  };

  main = config.system.services.prometheus-main.prometheus;
  alt = config.system.services.prometheus-alt.prometheus;

  # promtool is the `cli` output of the same package, not `bin`.
  promtool = "${pkgs.prometheus.cli}/bin/promtool";

  ask =
    instance: query:
    "${promtool} query instant http://127.0.0.1:${toString instance.port} ${lib.escapeShellArg query}";

  # Each instance scrapes itself, under a job name of its own. That is what
  # makes `up` say which instance answered.
  scrapeSelf = job: port: [
    {
      job_name = job;
      static_configs = [ { targets = [ "127.0.0.1:${toString port}" ]; } ];
    }
  ];
in
{
  system.services.prometheus-main = {
    imports = [ prometheusService ];
    prometheus.settings = {
      # 1s, not the default 15s: a check retries for 60s, and the first scrape
      # is what the `up` checks below wait for.
      global.scrape_interval = "1s";
      scrape_configs = scrapeSelf "dinix-main" 9090;
    };
  };

  system.services.prometheus-alt = {
    imports = [ prometheusService ];
    prometheus = {
      port = 9091;
      settings = {
        global.scrape_interval = "1s";
        scrape_configs = scrapeSelf "dinix-alt" 9091;
      };
    };
  };

  collection = {
    packages = [ pkgs.prometheus.cli ];

    writable = [
      main.dataDir
      alt.dataDir
    ];

    checks = [
      {
        # A constant, so it answers before the first scrape: this asks whether
        # the API is up and nothing else.
        name = "prometheus evaluates a query";
        command = ask main "vector(424242)";
        expect = "424242";
      }
      {
        # The scrape job comes from the configuration file, so this is what
        # says the file arrived, and a stored sample says the tsdb path is
        # writable.
        name = "and scrapes the job its configuration names";
        command = ask main ''up{job="dinix-main"}'';
        expect = ''job="dinix-main"'';
      }
      {
        name = "the second instance scrapes its own";
        command = ask alt ''up{job="dinix-alt"}'';
        expect = ''job="dinix-alt"'';
      }
      {
        # absent() answers 1 for a series that is not there, which is how a
        # substring match proves an absence.
        name = "and neither instance holds the other's series";
        command = ask main ''absent(up{job="dinix-alt"})'';
        expect = "=> 1";
      }
    ];
  };
}
