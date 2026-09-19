# The shape every ported service shares, so that porting one is filling in a
# form rather than deciding anything.
#
# It mirrors `multiService` in services-flake's nix/lib.nix deliberately: a
# port reads that repository's module for a service and maps it option for
# option. See PORTING.md.
rec {
  /**
    Where instances keep their data when no dataDir says otherwise.

    $DINIX_STATE_DIR when the evaluating environment sets it, /var/lib
    when it does not. An uncontainerized run has no volume to mount, so
    the environment names the state directory instead. getEnv is
    pure-safe: it reads "" outside impure evaluation, so flake consumers
    keep /var/lib without noticing.
  */
  stateDir =
    let
      env = builtins.getEnv "DINIX_STATE_DIR";
    in
    if env == "" then "/var/lib" else env;
  /**
    Turn a per-service module into a dinix module offering
    `<serviceName>.<instance>`.

    The module it takes declares the service's own options and sets
    `outputs`. Everything else — the attribute set of instances, `enable`,
    `dataDir`, the dinit service name, and collecting each instance's output
    into the top-level `services`, `dirs` and `mustExist` — happens here and
    is the same for every service.

    # Inputs

    `serviceName`
    : What the option is called, and the prefix of each dinit service name

    `mod`
    : A module evaluated once per instance, with `name` bound to the instance

    # Examples
    :::{.example}
    ## `multiService` usage example

    ```nix
    multiService "redis" (
      { name, config, pkgs, ... }:
      {
        options.port = lib.mkOption { type = lib.types.port; default = 6379; };
        config.outputs = {
          services.${config.serviceName} = { command = "..."; };
          dirs.${config.dataDir}.mode = "0700";
        };
      }
    )
    ```
    :::
  */
  multiService =
    serviceName: mod:
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) mkOption types;

      base =
        { name, config, ... }:
        {
          options = {
            enable = lib.mkEnableOption "the ${serviceName}.${name} service";

            dataDir = mkOption {
              type = types.str;
              default = "${stateDir}/${serviceName}/${name}";
              description = ''
                Where this instance keeps its data.

                An absolute path, not the working directory services-flake
                uses: a dinix service runs in a container, so this is a volume.
                dinix makes it before any service starts, which is why a ported
                service needs no shell to `mkdir` it.

                The default sits under $DINIX_STATE_DIR, or /var/lib when the
                variable is unset: an uncontainerized run has no volume to
                mount, so the environment names the state directory instead.
              '';
            };

            serviceName = mkOption {
              type = types.str;
              default = "${serviceName}-${name}";
              readOnly = true;
              description = ''
                What this instance is called in {option}`services`, and so to
                `dinitctl`. The instance name alone would collide between two
                services that share it.
              '';
            };

            outputs = {
              services = mkOption {
                type = types.lazyAttrsOf types.raw;
                default = { };
                internal = true;
                description = "dinit services this instance adds. See dinit-service(5).";
              };
              dirs = mkOption {
                type = types.lazyAttrsOf types.raw;
                default = { };
                internal = true;
                description = "Directories this instance needs made before anything starts.";
              };
              mustExist = mkOption {
                type = types.lazyAttrsOf types.raw;
                default = { };
                internal = true;
                description = "Paths this instance needs a volume to provide already.";
              };
            };
          };
        };

      instances = lib.filterAttrs (_: instance: instance.enable) config.${serviceName};

      collect = part: lib.concatMapAttrs (_: instance: instance.outputs.${part}) instances;
    in
    {
      options.${serviceName} = mkOption {
        # submoduleWith, not submodule: pkgs reaches a dinix module through
        # specialArgs, and a plain submodule does not inherit those.
        type = types.attrsOf (
          types.submoduleWith {
            specialArgs = { inherit pkgs; };
            modules = [
              base
              mod
            ];
          }
        );
        default = { };
        description = ''
          ${serviceName} instances, one attribute per instance. Each becomes a
          dinit service named `${serviceName}-<instance>`.
        '';
      };

      config = {
        services = collect "services";
        dirs = collect "dirs";
        mustExist = collect "mustExist";
      };
    };
}
