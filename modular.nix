# dinix as a service-manager implementation for NixOS Modular Services.
#
# A modular service says what to run without saying who runs it, so the same
# module works under systemd, under finit, and here. `lib.services.configure`
# is the documented door for a new implementation, and the manual's example is
# written for exactly this case — a manager that is not NixOS.
#
# See <https://nixos.org/manual/nixos/unstable/#modular-services>, and
# `lib/services/lib.nix` in nixpkgs for `configure`.
#
# The interface is new in NixOS 25.11 and the manual says significant changes
# should be expected, so this tracks it rather than wrapping it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  # The dinix configuration, under a name a service submodule's own `config`
  # does not shadow.
  topConfig = config;

  serviceLib = import ./service-lib.nix;

  /**
    One module, loaded into the root service submodule and into every
    sub-service, that does the two things an implementation has to do.

    It sets `configData.<name>.path`, which the portable layer declares and
    leaves to the manager, and it declares the `dinit` option tree that a
    service module targets with `lib.optionalAttrs (options ? dinit)` — the
    same way upstream's php module already targets `systemd` and `finit`.

    Recursive by hand, because `extraRootModules` reaches the root service
    only: propagating to sub-services is the module's own job. The systemd
    implementation does the same in `systemd/config-data-path.nix`.
  */
  dinitServiceModule =
    prefix:
    { name, ... }:
    let
      servicePrefix = "${prefix}${name}";
    in
    {
      _class = "service";

      options = {
        configData = mkOption {
          type = types.lazyAttrsOf (
            types.submodule (
              { config, ... }:
              {
                # Consolidated, the file goes inside configDir with everything
                # else dinix generates, and the marker is substituted for the
                # store path when that directory is built: no Nix expression
                # can name a store path before it exists, and a service
                # description in the same directory has the same problem. See
                # internal.initSpecPath.
                #
                # Split, the source is already a store path and needs no copy,
                # so the service reads the file where it is.
                config.path = lib.mkDefault (
                  if topConfig.consolidateConfig then
                    "@configDir@/system-services/${servicePrefix}/${config.name}"
                  else
                    toString config.source
                );
              }
            )
          );
        };

        dinit = {
          service = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            example = lib.literalExpression ''{ restart = true; term-signal = "INT"; }'';
            description = ''
              Settings written straight into this service's dinit description,
              as `services.<name>` takes them. See DINIT-SERVICE(5).

              This is the option tree a portable service module targets:

              ```nix
              lib.optionalAttrs (options ? dinit) {
                dinit.service.term-signal = "INT";
              }
              ```

              A module that does so still works where dinit is absent, because
              the attribute set is only added when this option exists.
            '';
          };

          stateDir = mkOption {
            type = types.str;
            readOnly = true;
            default = "${serviceLib.stateDir}/${servicePrefix}";
            description = ''
              Where this service should keep what it writes.

              Read by a service module for its own data directory default. The
              value is not a path but a template dinit expands when it loads
              the service, so one store path serves a container, an uncontained
              run and a systemd unit alike. See {option}`dirs`.

              The portable layer declares nothing like this — the manual lists
              per-service state as still to be decided — so a module that uses
              it is dinix-specific to that extent, and says so by reaching it
              through `options ? dinit`.
            '';
          };

          dirs = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            description = ''
              Directories to make before anything starts, as {option}`dirs`
              takes them. The portable layer has no answer for this, and under
              systemd the same module would say `StateDirectory` instead.
            '';
          };

          mustExist = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            description = ''
              Paths a volume has to provide already, as {option}`mustExist`
              takes them.
            '';
          };

          users = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            description = ''
              Accounts this service needs in the user database, as
              {option}`users.users` takes them. Declaring one turns the
              database on.

              A service that refuses to start without an account of its own —
              sshd without its privilege separation user, for one — has no
              portable way to say so: the manual lists per-service users as
              still to be decided. Under systemd the same module would say
              `DynamicUser` or leave it to a sysusers file.
            '';
          };

          groups = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            description = ''
              Groups this service needs, as {option}`users.groups` takes them.
              See {option}`dinit.users`.
            '';
          };
        };

        services = mkOption {
          type = types.attrsOf (
            types.submoduleWith {
              modules = [ (dinitServiceModule "${servicePrefix}-") ];
            }
          );
        };
      };
    };

  modular = lib.services.configure {
    serviceManagerPkgs = pkgs;
    extraRootModules = [ (dinitServiceModule "") ];
  };

  /**
    A service and everything below it, as dinit service descriptions.

    A sub-service is an ownership relation and nothing more — the manual is
    explicit that it creates no dependency by itself — so this names them and
    wires nothing. A module that wants an order says so through `dinit.service`.
  */
  renderService =
    dinitName: service:
    {
      ${dinitName} = {
        type = "process";
        # dinit takes one command line, not an argument vector, and splits it
        # on whitespace. Every argument is quoted so that one holding a space
        # stays one argument. escapeShellArg would be wrong: dinit is not a
        # shell, and its own rule is double quotes with backslash escapes.
        command = lib.concatMapStringsSep " " quoteArgument service.process.argv;
      }
      // service.dinit.service;
    }
    // lib.concatMapAttrs (
      childName: child: renderService "${dinitName}-${childName}" child
    ) service.services;

  # dinit-service(5): double quotes around all or part of a value, and a
  # backslash escapes the next character even inside them.
  quoteArgument = argument: ''"${lib.escape [ "\\" "\"" ] (toString argument)}"'';

  # `dinit.dirs`, `dinit.mustExist`, `dinit.users` and `dinit.groups` of a
  # service and of everything below it.
  collect =
    part: service:
    service.dinit.${part} // lib.concatMapAttrs (_: child: collect part child) service.services;

  collectAll = part: lib.concatMapAttrs (_: service: collect part service) config.system.services;

  # Every configData entry of a service and of everything below it, as the
  # relative path inside configDir it is written at.
  renderConfigData =
    servicePrefix: service:
    lib.concatMapAttrs (
      _: item:
      lib.optionalAttrs item.enable {
        "system-services/${servicePrefix}/${item.name}" = item.source;
      }
    ) service.configData
    // lib.concatMapAttrs (
      childName: child: renderConfigData "${servicePrefix}-${childName}" child
    ) service.services;
in
{
  options.system.services = mkOption {
    type = types.attrsOf modular.serviceSubmodule;
    default = { };
    description = ''
      [Modular services](https://nixos.org/manual/nixos/unstable/#modular-services),
      run by dinit.

      Named `system.services` because that is what NixOS calls it, so a
      configuration moves between the two unchanged:

      ```nix
      system.services.my-tunnel = {
        imports = [ pkgs.ghostunnel.services.default ];
        ghostunnel.listen = "127.0.0.1:8443";
      };
      ```

      Each becomes a dinit service of the same name, and a sub-service becomes
      `<parent>-<child>`. Nothing here attaches them to `boot`: set
      {option}`services.<name>.dinix.critical`, as for any other service.

      **The portable layer declares no state, no user and no ownership**, so
      dinix adds a `dinit` tree to every service for them: {option}`dinit.dirs`,
      {option}`dinit.users`, {option}`dinit.groups` and `dinit.service.run-as`.
      A module reaches them through `options ? dinit` and still evaluates
      elsewhere. See issue #15.

      `process.reloadCommand` and `process.reloadSignal` are ignored: dinit has
      no reload. `dinitctl signal` sends one by hand.
    '';
  };

  config = {
    services = lib.concatMapAttrs renderService config.system.services;

    dirs = collectAll "dirs";
    mustExist = collectAll "mustExist";

    users.users = collectAll "users";
    users.groups = collectAll "groups";
    # A service that asks for an account needs somewhere to put it, and a
    # configuration that asks for none pays nothing.
    users.enable = lib.mkIf (collectAll "users" != { } || collectAll "groups" != { }) true;

    # Nothing to write when the files are not consolidated: each one is its own
    # store path and the service description names it directly.
    internal.configDataFiles = lib.optionalAttrs config.consolidateConfig (
      lib.concatMapAttrs (name: service: renderConfigData name service) config.system.services
    );

    # Per service rather than over a synthetic root: these walk a service
    # config and read its own `assertions`, `warnings` and `services`, and a
    # made-up root has none of the first two.
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        name: service:
        lib.services.getAssertions [
          "system"
          "services"
          name
        ] service
      ) config.system.services
    );
    warnings = lib.concatLists (
      lib.mapAttrsToList (
        name: service:
        lib.services.getWarnings [
          "system"
          "services"
          name
        ] service
      ) config.system.services
    );
  };
}
