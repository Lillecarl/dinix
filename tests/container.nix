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
      # sshd's StrictModes walks every parent of the keys file, and
      # /nix/store is group-writable, so a keys file in the store fails it.
      StrictModes = false;
      # A refused login has to explain itself in the container's own log,
      # which is the only evidence the test collects. VERBOSE and not DEBUG1:
      # DEBUG1 also sends its lines down the session, so a command's output
      # comes back with sshd's log mixed into it.
      LogLevel = "VERBOSE";
    };
  };

  # sshd is the reason this container exists, so stopping it must stop the
  # container. The test checks that.
  services.sshd.dinix.critical = true;
}
