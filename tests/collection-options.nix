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

    tmpfs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Writable paths the services need, on top of `/run`.

        The containers mount one state directory and dinix-init makes
        these inside it, so this list is what the vm modes make on the
        guest instead. Either way every path here has to work, which also
        puts {option}`dirs` under test: a service only starts if dinix-init
        set the mode the program insists on.
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
