# What a collection declares for the test harness, on top of an ordinary dinix
# configuration. Only dev.nix imports this, so `collection` is not part of
# dinix's own interface.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.collection = {
    services = mkOption {
      type = types.listOf types.str;
      default = lib.attrNames (lib.removeAttrs config.services [ "boot" ]);
      description = ''
        The dinit services the test waits for. Every service but `boot` by
        default, which is what a collection wants: a service that never starts
        is the failure being looked for.
      '';
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Extra packages for the image, on top of what the services reference.

        A check that asks the service a question needs a client, and a service
        package rarely ships one: memcached has a server only, and the image
        holds the closure of the services and nothing else. The client — bash
        to pipe a request into `nc`, say — goes here, and the check names its
        absolute store path.
      '';
    };

    writable = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Paths that have to be writable at runtime, on top of `/run`.

        dinit's control socket lives in `/run`, which every deployment
        provides; everything a service keeps lives under one of these. A
        read-only deployment mounts exactly these — emptyDirs at these paths
        beside `/run` — so this list staying complete is what keeps such a
        deployment working.

        **Nothing in the test makes them.** dinix-init does, from
        {option}`dirs`, in every mode. A driver that made them first would
        hide the failure this is here to catch: a service whose directory
        dinix never declared.
      '';
    };

    checks = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "What this proves, said as the test will print it.";
            };
            command = mkOption {
              type = types.str;
              description = ''
                Run inside the container with `podman exec`, which takes an
                argument list and no shell. Name an absolute store path, so a
                collection image needs no shell and no PATH.
              '';
            };
            expect = mkOption {
              type = types.str;
              description = "Text the output has to contain. The command must also succeed.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Questions to ask the running container, in order. They run after every
        service has started, and a later one may depend on an earlier one
        having run.
      '';
    };
  };
}
