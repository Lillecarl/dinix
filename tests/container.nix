# The dinix configuration the container test runs. sshd is the subject: it is
# the fussiest common daemon about paths and permissions, so it exercises
# dirs, the user database and the log routing in one container.
{
  clientKey,
  pkgs,
  lib,
  ...
}:
{
  system.services.sshd = {
    imports = [ (lib.modules.importApply ../services/openssh.nix { inherit (pkgs) openssh; }) ];

    # Keys made at startup rather than mounted, so the test covers the
    # sshd-keygen sub-service and the directory dinix-init makes for it.
    openssh.generateHostKeys.enable = true;
    openssh.settings = {
      Port = 2222;
      PermitRootLogin = "prohibit-password";
      AuthorizedKeysFile = "${clientKey}/authorized_keys";
      # StrictModes walks every parent directory of the keys file, and what
      # /nix/store looks like inside an image is the image builder's choice.
      # The test is not about that.
      StrictModes = false;
      # A refused login has to explain itself in the container's own log,
      # which is the only evidence the test collects. VERBOSE and not DEBUG1:
      # DEBUG1 also sends its lines down the session, so a command's output
      # comes back with sshd's log mixed into it.
      LogLevel = "VERBOSE";
    };
  };

  # A volume the container cannot do without. The test runs the container both
  # with it and without it: mounted, nothing happens, and missing, the
  # container stops before sshd starts and says which path was not there.
  mustExist."/data".kind = "dir";

  # A directory inside that volume, so the test can also run the container with
  # a symlink planted where this goes. dinix-init must refuse it: create_dir_all
  # is happy with a symlink to a directory, and both set_permissions and chown
  # follow one, so anything able to plant it would otherwise choose what gets
  # chowned.
  dirs."/data/logs".mode = "0750";

  caCertificates.enable = true;

  # Set here rather than printed by the service, because dinit execs a command
  # directly with no shell and would pass "$MARKER" through unexpanded.
  env-file.variables.DINIX_MARKER = "dinix-buffer-marker";

  # Output that must not reach the collected stream. A container runtime
  # collects what PID 1 writes and nothing else, so a service too chatty for
  # that stream goes to a ring buffer instead, readable with dinitctl catlog.
  #
  # It prints its environment, so one service answers three questions: whether
  # the buffer keeps the output, whether the collected stream stays clear of
  # it, and whether dinit's own env-file reaches a service at all.
  services.chatty = {
    type = "scripted";
    command = "${pkgs.busybox}/bin/env";
    dinix.log = "buffer";
    dinix.critical = false;
  };

  # sshd is the reason this container exists, so stopping it must stop the
  # container. The test checks that.
  system.services.sshd.dinit.service.dinix.critical = true;
}
