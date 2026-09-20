# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# Mailpit is authored as a NixOS Modular Service, so an instance is one
# `system.services` entry importing the module. See services/mailpit.nix and
# PORTING.md.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  mailpitService = lib.modules.importApply ../../services/mailpit.nix {
    inherit (pkgs) mailpit;
  };

  main = config.system.services.mailpit-main.mailpit;
  alt = config.system.services.mailpit-alt.mailpit;

  bash = "${pkgs.bash}/bin/bash";
  curl = "${pkgs.curl}/bin/curl";

  api = instance: path: "${curl} --silent --fail http://127.0.0.1:${toString instance.uiPort}${path}";

  # The message arrives on curl's standard input, which takes a shell for the
  # pipe. Not a store path with the message in it: a container holds the
  # image's closure, and nothing in the configuration would reference such a
  # file, so `--upload-file /nix/store/…` fails with curl's exit 26.
  send =
    instance: subject:
    "${bash} -c ${
      lib.escapeShellArg (
        "printf 'From: dinix@example.invalid\\nTo: box@example.invalid\\nSubject: ${subject}\\n\\nsent by the collection\\n'"
        + " | ${curl} --silent --show-error smtp://127.0.0.1:${toString instance.smtpPort}"
        + " --mail-from dinix@example.invalid --mail-rcpt box@example.invalid --upload-file -"
      )
    }";
in
{
  system.services.mailpit-main = {
    imports = [ mailpitService ];
  };

  # A second instance on its own ports, with its own database. Two of them is
  # what catches instances sharing state.
  system.services.mailpit-alt = {
    imports = [ mailpitService ];
    mailpit = {
      uiPort = 8026;
      smtpPort = 1026;
    };
  };

  collection = {
    packages = [
      pkgs.bash
      pkgs.curl
    ];

    writable = [
      main.dataDir
      alt.dataDir
    ];

    checks = [
      {
        name = "mailpit answers on its API";
        command = api main "/api/v1/info";
        expect = "Version";
      }
      {
        name = "and accepts a message over SMTP";
        command = send main "dinix-to-main";
        # curl prints nothing on a delivered message, so the exit status is
        # the check. An empty expect matches any output, including none.
        expect = "";
      }
      {
        name = "which the API then lists";
        command = api main "/api/v1/messages";
        expect = "dinix-to-main";
      }
      {
        name = "the second instance takes its own";
        command = send alt "dinix-to-alt";
        expect = "";
      }
      {
        # Distinct subjects rather than a count: the second instance holding
        # only its own is what says the two keep separate mailboxes.
        name = "and the two keep separate mailboxes";
        command = api alt "/api/v1/messages";
        expect = "dinix-to-alt";
      }
    ];
  };
}
