# The dinix configuration the container test runs. sshd is the subject: it is
# the fussiest common daemon about paths and permissions, so it exercises
# dirs, the user database and the log routing in one container.
{ clientKey, ... }:
{
  openssh = {
    enable = true;
    # Keys made at startup rather than mounted, so the test covers the
    # sshd-keygen service and the directory dinix-init makes for it.
    generateHostKeys.enable = true;
    settings = {
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

  # sshd is the reason this container exists, so stopping it must stop the
  # container. The test checks that.
  services.sshd.dinix.critical = true;
}
