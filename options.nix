{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The service submodule shadows `config` with its own. This keeps the
  # top-level one reachable from inside it.
  topConfig = config;

  inherit (lib)
    attrNames
    attrsToList
    concatLines
    filter
    generators
    getExe
    getExe'
    hasPrefix
    isBool
    isDerivation
    isList
    mapAttrsToList
    mergeEqualOption
    mkBefore
    mkDefault
    mkIf
    mkOption
    mkOptionType
    optionalString
    pipe
    types
    ;

  dinixStringLikePlusType = mkOptionType {
    name = "stringLikePlus";
    description = "Something stringlike + numbers";
    descriptionClass = "noun";
    check = isStringLikePlus;
    merge = mergeEqualOption;
  };
  dinixListType = types.nullOr (types.listOf dinixStringLikePlusType);

  isStringLikePlus =
    value: value == null || (!isList value && lib.strings.isConvertibleWithToString value);
  toStringPlus = value: if isBool value then lib.boolToString value else toString value;

  mkDinitOption =
    attrs:
    mkOption (
      {
        type = dinixStringLikePlusType;
        description = "See DINIT-SERVICE(5)";
        default = null;
      }
      // attrs
    );

  mkDinitListOption = attrs: mkDinitOption ({ type = dinixListType; } // attrs);

  # getExe guesses <out>/bin/<pname> when meta.mainProgram is missing, which is
  # wrong for a single-file derivation such as writeShellScript. Those already
  # point at the executable, so use them as they are.
  toCommand =
    value:
    if !isDerivation value then
      value
    else if value.meta.mainProgram or null != null then
      getExe value
    else
      "${value}";

  envfileType = types.submodule (
    { config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          description = ''
            Whether to pass this file to dinit. Set by default when any other
            option in this set is not at its default.
          '';
        };
        clear = mkOption {
          type = types.bool;
          default = false;
          description = "Clear all environment variables";
        };
        variables = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Environment variables to set";
        };
        unset = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of variables to unset";
        };
        import = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of variables to import from the ambient environment";
        };
        text = mkOption {
          type = types.str;
          description = "Rendered env-file text";
          internal = true;
        };
        file = mkOption {
          type = types.package;
          description = "Rendered env-file";
          internal = true;
        };
      };
      config = {
        enable = mkDefault (
          config.clear || config.variables != { } || config.unset != [ ] || config.import != [ ]
        );
        text = ''
          # dinit environment file. See DINIT(8)
          ${optionalString config.clear "!clear"}
          ${concatLines (map (x: "!unset ${x}") config.unset)}
          ${generators.toKeyValue {
            mkKeyValue = generators.mkKeyValueDefault { } "=";
          } config.variables}
          ${concatLines (map (x: "!import ${x}") config.import)}
        '';
        file = pkgs.writeText "env-file" config.text;
      };
    }
  );

  # A dinit service description. The freeform type covers every option in
  # dinit-service(5); the declared ones below only add conversions on top.
  # An option the manpage writes with a colon suffix (depends-on:) takes a Nix
  # list here, and each element becomes its own line.
  serviceType = types.submodule (
    { config, ... }:
    {
      freeformType = types.attrsOf (types.either dinixListType dinixStringLikePlusType);

      options = {
        type = mkDinitOption {
          default = "process";
        };
        command = mkDinitOption {
          apply = toCommand;
        };
        stop-command = mkDinitOption {
          apply = toCommand;
        };
        env-file = mkDinitOption {
          type = types.nullOr (types.either types.path envfileType);
          apply = value: if value.enable or false then value.file else value;
        };
        text = mkDinitOption {
          type = types.str;
          internal = true;
        };

        # dinix writes to these six itself. A freeform attribute cannot hold a
        # value derived from config: the freeform merge forces every freeform
        # value to decide which attributes exist, so such a value would be its
        # own input. Declaring them keeps them lazy. They behave exactly as the
        # freeform ones do otherwise.
        depends-on = mkDinitListOption { };
        waits-for = mkDinitListOption { };
        options = mkDinitListOption { };
        restart = mkDinitOption { };
        restart-delay = mkDinitOption { };
        restart-limit-count = mkDinitOption { };
        log-type = mkDinitOption { };
        logfile = mkDinitOption { };
        log-buffer-size = mkDinitOption { };

        dinix = mkOption {
          type = types.submodule {
            options = {
              critical = mkOption {
                type = types.nullOr types.bool;
                default = null;
                description = ''
                  Whether dinit must exit when this service stops, so that a
                  container runtime restarts the whole container.

                  `true` makes the boot service depend on this one, and turns
                  off boot's own restart. When the service stops for any
                  reason, boot stops, every service stops, and dinit exits.

                  `false` makes boot wait for this one instead. The service can
                  die and restart forever without dinit noticing.

                  `null`, the default, wires nothing. Write the dependencies of
                  the boot service yourself.

                  Setting `smooth-recovery` on a critical service cancels this.
                  Smooth recovery restarts the process in place without
                  stopping dependents, so boot never stops and dinit never
                  exits. Measured against dinit 0.22.1.
                '';
              };
              log = mkOption {
                type = types.enum [
                  "console"
                  "buffer"
                  "file"
                  "none"
                ];
                description = ''
                  Where this service's output goes.

                  `console` gives it `shares-console`, so the output joins the
                  stream dinit itself writes to. That is the only stream a
                  container runtime collects. Output passes through unchanged;
                  dinit adds no prefix, so JSON log lines stay parseable. The
                  default for process, bgprocess and scripted services.

                  `buffer` keeps the output in memory, readable with
                  `dinitctl catlog`. A ring buffer cannot grow without bound,
                  which makes this the one destination that needs no rotation.
                  Use it for a service too chatty for the collected stream.
                  See {option}`logBufferSize`.

                  `file` writes to {option}`logfile`. **dinit does not rotate,
                  and the file grows without bound**, so whatever owns the
                  volume has to own the rotation. The default when `logfile` is
                  set.

                  `none` discards the output, which is dinit's own default.

                  `console` and `file` are exclusive: dinit-service(5) says
                  `logfile` has no effect on a service that shares the console.
                  dinix picks `file` for you when you set `logfile`, rather than
                  letting the console default silently win.

                  Set this rather than `log-type`. `log-type` follows from it,
                  so setting `log-type` by hand leaves a process service sharing
                  the console, and dinit then ignores the log type.
                '';
              };
              logDir = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  A directory this service writes log files into by itself.

                  This declares a fact rather than changing dinit's behaviour.
                  Some applications keep their own log files and cannot be
                  pointed at standard error: Phorge's `phd` writes one file per
                  daemon, rotates them itself, and reads them back.

                  Naming the directory here puts it in the top-level
                  {option}`logDirs`, so whatever builds the container derives
                  the volume and its size from the service definition instead of
                  matching two independent facts by hand.
                '';
              };
              logDirSize = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  How large {option}`dinix.logDir` is allowed to get, as the
                  consumer's own size syntax, for example `64Mi` for a
                  Kubernetes `emptyDir`. Carried through to
                  {option}`logDirs` untouched.
                '';
              };
            };
          };
          default = { };
          description = ''
            Settings dinix acts on itself. These never reach the service file.
          '';
        };
      };

      config =
        let
          settings = pipe config [
            attrsToList
            # text is this attribute, and dinix holds settings dinit never sees.
            (filter (
              opt:
              !(builtins.elem opt.name [
                "text"
                "dinix"
              ])
              && opt.value != null
            ))
          ];
          # @include and friends are directives, not assignments.
          toKV =
            name: value:
            if hasPrefix "@" name then "${name} ${toStringPlus value}" else "${name} = ${toStringPlus value}";
        in
        {
          # Reading a declared sibling is fine; reading a freeform one with
          # `or` is not, because that forces config's key set. log-type and
          # logfile are declared above for exactly this.
          # Only logfile may be read here. log-type derives from this setting,
          # so reading it too would make the two each other's input.
          dinix.log = mkDefault (
            if config.logfile != null then
              "file"
            else if
              builtins.elem config.type [
                "process"
                "bgprocess"
                "scripted"
              ]
            then
              "console"
            else
              "none"
          );

          # Every definition below is unconditional, and carries the condition
          # in its value instead. mkIf here would put config in its own
          # condition: a freeform submodule resolves which definitions exist
          # before config exists, so the condition cannot read config.
          options = mkBefore (lib.optional (config.dinix.log == "console") "shares-console");

          # none is dinit's own default, and console is an option rather than a
          # log type, so neither needs a line.
          log-type = mkDefault (
            if
              builtins.elem config.dinix.log [
                "buffer"
                "file"
              ]
            then
              config.dinix.log
            else
              null
          );
          log-buffer-size = mkDefault (
            if config.dinix.log == "buffer" then topConfig.logBufferSize else null
          );

          # dinit gives up after 3 restarts in 10 seconds. A service that boot
          # only waits for is meant to outlive its own crashes, so lift the
          # limit and slow the loop down; an exporter that fails instantly
          # would otherwise flood the one log stream a pod has.
          restart-limit-count = mkDefault (if config.dinix.critical == false then 0 else null);
          restart-delay = mkDefault (if config.dinix.critical == false then 5 else null);

          text = concatLines (
            (pipe settings [
              (filter (opt: isStringLikePlus opt.value))
              (map (opt: toKV opt.name opt.value))
            ])
            ++ (pipe settings [
              (filter (opt: isList opt.value))
              # Two modules asking for the same dependency, or for an option
              # dinix also sets, must not write the line twice.
              (map (opt: map (listVal: "${opt.name}: ${toStringPlus listVal}") (lib.unique opt.value)))
              lib.flatten
            ])
          );
        };
    }
  );
in
{
  imports = [
    ./users.nix
  ];

  options = {
    name = mkOption {
      type = types.str;
      default = "dinixLauncher";
      description = "Derivation name for the generated wrappers.";
    };

    services = mkOption {
      type = types.attrsOf serviceType;
      default = { };
      description = "dinit services, one attribute per service. See dinit-service(5).";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.dinit;
      description = ''
        The dinit package to configure, wrap and verify against.

        {option}`trimShutdownTools` acts on this. What the wrappers actually
        use is {option}`internal.dinitPackage`.
      '';
    };

    trimShutdownTools = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to drop `shutdown`, `halt`, `poweroff`, `reboot` and
        `soft-reboot` from {option}`package`.

        Those five call `/bin/umount` and `/sbin/swapoff`, which nixpkgs
        rewrites to point at util-linux. That puts five util-linux outputs in
        the closure of every container, `mount` and `login` among them. dinit
        reaches none of it in container mode: `--container` makes it exit
        instead of running a shutdown program.

        Measured on a configuration with one service: 57.9 MiB over 17 store
        paths with the tools, 46.6 MiB over 9 without.
      '';
    };

    env-file = mkOption {
      type = types.nullOr (types.either types.path envfileType);
      apply = value: if value.enable or false then value.file else value;
      default = null;
      description = ''
        Environment file dinit itself reads, applied to every service. Either a
        path, or an attribute set rendered into one. See dinit(8).
      '';
    };

    verifyConfig = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to run dinit-check over the rendered services at build time.";
    };

    socketPath = mkOption {
      type = types.str;
      default = "/run/dinitctl";
      description = ''
        Where dinit puts its control socket, and where the wrapped `dinitctl`
        and `dinit-monitor` look for it.

        This is dinit's own compiled-in default. **dinit exits 1 at startup
        when it cannot create this socket**, so on a read-only root filesystem
        this must name a writable volume. Under Kubernetes that means the path
        an `emptyDir` is mounted at, and `/dev` does not serve: the kubelet
        creates it mode 755 owned by root, so a container running as a normal
        user cannot write there either.
      '';
    };

    logBufferSize = mkOption {
      type = types.int;
      default = 262144;
      description = ''
        Bytes of output kept for a service with `dinix.log = "buffer"`.

        dinit's own default is 4096, and it discards everything past the limit,
        so a service of any volume keeps only its last few lines. 256 KiB holds
        enough to explain a crash.
      '';
    };

    logDirs = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            path = mkOption {
              type = types.str;
              description = "The directory the service writes into.";
            };
            size = mkOption {
              type = types.nullOr types.str;
              description = "How large it may get, in the consumer's own syntax.";
            };
          };
        }
      );
      readOnly = true;
      description = ''
        Every directory a service declared through `dinix.logDir`, keyed by
        service name.

        Read this when building the container, so the volumes and their limits
        come from the service definitions rather than from a second list kept
        in step by hand.
      '';
    };

    quiet = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to stop dinit writing its own service status lines, the
        `[  OK  ]` and `[STOPPD]` chatter, to standard output.

        Service output is not affected. Where a log collector reads only the
        output of PID 1, these lines land in the same stream as the services
        and break a reader that expects one format per stream.
      '';
    };

    consoleLevel = mkOption {
      type = types.nullOr (
        types.enum [
          "none"
          "error"
          "warn"
          "info"
          "debug"
        ]
      );
      default = "warn";
      description = ''
        How much of dinit's own logging reaches the console.

        {option}`quiet` alone also silences this. The default puts it back at
        `warn`, which keeps the "Service <name> process terminated with exit
        code N" line. That line names the service that brought the container
        down, and nothing else reports it.
      '';
    };

    userWrapper = mkOption {
      type = types.package;
      description = ''
        dinit and its tools, wrapped to read this configuration straight from
        the store. For running a dinix configuration as an unprivileged user:
        `dinit --user`.
      '';
    };

    containerWrapper = mkOption {
      type = types.package;
      description = ''
        dinit as PID 1 of a container, reading its services straight from the
        store.

        A plain binary wrapper, so the image needs no shell, no coreutils and
        no writable root filesystem. Setting {option}`users.installAtRuntime`
        makes it a shell script instead, and puts a shell in the closure.

        `meta.mainProgram` is `dinit`, so `lib.getExe` resolves it and the
        whole thing symlinks into a larger environment.
      '';
    };

    internal = mkOption {
      type = types.submodule {
        options = {
          services-dir = mkOption {
            type = types.package;
            description = "Directory holding one rendered file per service.";
          };
          dinitPackage = mkOption {
            type = types.package;
            description = "package, with the shutdown tools removed if asked for.";
          };
          envfileArg = mkOption {
            type = types.str;
            description = "The --env-file argument, or the empty string.";
          };
          checkArgs = mkOption {
            type = types.str;
            description = "Flags dinit-check accepts: the services directory and the env-file.";
          };
          dinitArgs = mkOption {
            type = types.str;
            description = "Flags every wrapped dinit gets, whatever the mode.";
          };
          containerArgs = mkOption {
            type = types.str;
            description = "Flags the container wrapper adds on top of dinitArgs.";
          };
          usersInstallScript = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Script that installs the user database into the rootfs.";
          };
        };
      };
      description = ''
        Intermediate results on the way from these options to a derivation
        holding a complete dinit configuration.
      '';
      internal = true;
      default = { };
    };
  };

  config = {
    logDirs = pipe config.services [
      (lib.filterAttrs (_: service: service.dinix.logDir != null))
      (lib.mapAttrs (
        _: service: {
          path = service.dinix.logDir;
          size = service.dinix.logDirSize;
        }
      ))
    ];

    services.boot =
      let
        named =
          wanted:
          pipe config.services [
            (lib.filterAttrs (serviceName: service: serviceName != "boot" && service.dinix.critical == wanted))
            attrNames
          ];
        critical = named true;
      in
      {
        type = mkDefault "internal";
        depends-on = critical;
        waits-for = named false;
        # boot restarts by default, which would bring a dead critical service
        # back up and keep dinit alive. Measured against dinit 0.22.1.
        restart = mkDefault (if critical == [ ] then null else false);
      };

    internal = {
      dinitPackage =
        if !config.trimShutdownTools then
          config.package
        else
          config.package.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              for tool in shutdown halt poweroff reboot soft-reboot; do
                rm --force "$out/bin/$tool" "$out/share/man/man8/$tool.8.gz"
              done
            '';
          });

      envfileArg = optionalString (config.env-file != null) "--env-file ${config.env-file}";

      checkArgs = lib.concatStringsSep " " (
        [ "--services-dir ${config.internal.services-dir}" ]
        ++ lib.optional (config.internal.envfileArg != "") config.internal.envfileArg
      );

      # dinit-check takes neither of these, so it gets checkArgs instead.
      dinitArgs = lib.concatStringsSep " " (
        [ config.internal.checkArgs ]
        ++ lib.optional config.quiet "--quiet"
        ++ lib.optional (config.consoleLevel != null) "--console-level ${config.consoleLevel}"
      );

      containerArgs = lib.concatStringsSep " " [
        "--container"
        "--socket-path ${config.socketPath}"
      ];

      services-dir = pkgs.runCommand "dinix-services" { } (
        concatLines (
          [ "mkdir --parents $out" ]
          ++ (mapAttrsToList (
            serviceName: service:
            "cp ${pkgs.writeText "dinix-service-${serviceName}" service.text} $out/${serviceName}"
          ) config.services)
          ++ lib.optional config.verifyConfig "${getExe' config.internal.dinitPackage "dinit-check"} ${config.internal.envfileArg} --services-dir $out"
        )
      );
    };

    userWrapper =
      pkgs.runCommand "${config.name}-user"
        {
          nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
          meta.mainProgram = "dinit";
        }
        ''
          mkdir --parents $out/bin
          makeBinaryWrapper ${getExe' config.internal.dinitPackage "dinit"} $out/bin/dinit \
            --add-flags "${config.internal.dinitArgs}"
          makeBinaryWrapper ${getExe' config.internal.dinitPackage "dinit-check"} $out/bin/dinit-check \
            --add-flags "${config.internal.checkArgs}"
          ln --symbolic ${getExe' config.internal.dinitPackage "dinitctl"} $out/bin/dinitctl
          ln --symbolic ${getExe' config.internal.dinitPackage "dinit-monitor"} $out/bin/dinit-monitor
        '';

    containerWrapper =
      let
        # dinit never writes to its services directory, so it reads them from
        # the store and the container needs nothing writable for them.
        # Measured against dinit 0.22.1 with the directory chmod a-w.
        entrypoint =
          if config.internal.usersInstallScript == null then
            ''
              makeBinaryWrapper ${getExe' config.internal.dinitPackage "dinit"} $out/bin/dinit \
                --add-flags "${config.internal.dinitArgs} ${config.internal.containerArgs}"
            ''
          else
            ''
              cat > $out/bin/dinit <<EOF
              #! ${pkgs.runtimeShell}
              set -euo pipefail
              ${getExe config.internal.usersInstallScript}
              exec ${getExe' config.internal.dinitPackage "dinit"} ${config.internal.dinitArgs} ${config.internal.containerArgs} "\$@"
              EOF
              chmod +x $out/bin/dinit
            '';
      in
      pkgs.runCommand "${config.name}-container"
        {
          nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
          meta.mainProgram = "dinit";
        }
        ''
          mkdir --parents $out/bin
          ${entrypoint}
          # dinitctl reads DINIT_SOCKET_PATH, so these work from an absolute
          # store path with no PATH and no terminal, which is all a debugging
          # exec into a scratch image has.
          makeBinaryWrapper ${getExe' config.internal.dinitPackage "dinitctl"} $out/bin/dinitctl \
            --set-default DINIT_SOCKET_PATH ${config.socketPath}
          makeBinaryWrapper ${getExe' config.internal.dinitPackage "dinit-monitor"} $out/bin/dinit-monitor \
            --set-default DINIT_SOCKET_PATH ${config.socketPath}
        '';
  };
}
