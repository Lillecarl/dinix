# What a service and the code around it both have to agree on.
#
# One value, because a ported service is a NixOS Modular Service now and the
# interface supplies the rest. See PORTING.md.
{
  /**
    Where instances keep their data when no `dataDir` says otherwise.

    **This is a literal string that dinit expands, not a path decided here.**
    dinit substitutes variables in a service description when it loads it, so
    `DINIX_STATE_DIR` is read at startup from dinit's own environment and one
    store path serves every way of running: a rootful container, a rootless
    one, an uncontained run, a systemd unit. Nothing rebuilds to move state.
    See `dinit-service(5)`, VARIABLE SUBSTITUTION.

    `dinix-init` does the same expansion over `init.spec`, so the directory it
    makes and the path the service opens agree. See `dinix-init/src/expand.rs`.

    It cannot be `builtins.getEnv`. That reads the *evaluating* environment,
    which bakes one mode's path into the store and gives the same commit two
    different output hashes depending on a variable the consumer never set on
    purpose. Measured before it was removed: `/var/lib` and `/srv/state` from
    one revision.

    **A path that ends up inside a configuration file the program reads is not
    covered**, because the program does the reading and knows nothing of this.
    Put it on the command line, where dinit substitutes, or use the program's
    own prefix flag. See PORTING.md.
  */
  stateDir = "\${DINIX_STATE_DIR:-/var/lib}";
}
