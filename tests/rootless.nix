# The rootless half of the container test: sshd as an ordinary user.
#
# sshd decides by its own uid whether it separates privileges, so this is a
# second image and not a second flag on the first one.
_: {
  system.services.sshd.openssh.rootless = true;

  # A rootless sshd asks for no account of its own, so nothing else turns the
  # database on. The one account below is still needed, and sshd fails a login
  # it cannot find in passwd.
  users.enable = true;

  # A rootless sshd serves one account and cannot change uid, so this has to be
  # the uid the container runs as. /bin/sh comes from the busybox the image
  # carries; sshd refuses an account whose shell does not exist.
  users.users.app = {
    uid = 1000;
    gid = 1000;
    comment = "The one account a rootless sshd can serve";
    homeDir = "/home/app";
    shell = "/bin/sh";
  };
  users.groups.app.gid = 1000;
}
