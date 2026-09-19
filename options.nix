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

  # Whether there is any init work, and so a dinix-init service to order
  # against. Read from inside the service submodule, so it must not depend on
  # config.services.
  needsInit = config.dirs != { } || config.mustExist != { };

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

  /**
    Write an attribute set of relative path to text as one store path.

    Contents go through `passAsFile`, so a large service tree does not hit the
    command line length limit. `extra` runs once every file is in place, which
    is where the dinit-check goes: a relative `env-file` only resolves once the
    layout is finished.
  */
  writeFiles =
    name: files: extra:
    let
      indexed = lib.imap0 (index: entry: entry // { inherit index; }) (
        lib.mapAttrsToList (path: text: { inherit path text; }) files
      );
      # "$file" then the index keeps the dollar away from a brace, which would
      # otherwise read as Nix interpolation and leave a literal $$ for the
      # shell to expand into its own pid.
      varOf = entry: "file${toString entry.index}";
    in
    pkgs.runCommand name
      (
        {
          passAsFile = map varOf indexed;
        }
        // lib.listToAttrs (map (entry: lib.nameValuePair (varOf entry) entry.text) indexed)
      )
      (
        concatLines (
          (map (entry: ''
            mkdir --parents "$out/$(dirname ${lib.escapeShellArg entry.path})"
            cp "$file${toString entry.index}Path" "$out/${entry.path}"
          '') indexed)
          ++ [ extra ]
        )
      );

  # Runs inside the derivation being built, against the layout there, because
  # a relative env-file resolves against the directory holding the service.
  checkCommand =
    servicesSubdir:
    optionalString config.verifyConfig ''
      ${getExe' config.internal.dinitPackage "dinit-check"} --services-dir "$out/${servicesSubdir}"
    '';

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
      };
    }
  );

  # A dinit service description. The freeform type covers every option in
  # dinit-service(5); the declared ones below only add conversions on top.
  # An option the manpage writes with a colon suffix (depends-on:) takes a Nix
  # list here, and each element becomes its own line.
  serviceType = types.submodule (
    { name, config, ... }:
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
        };
        text = mkDinitOption {
          type = types.str;
          internal = true;
        };
        envFileText = mkOption {
          type = types.nullOr types.str;
          internal = true;
          description = "Rendered env-file text, when env-file is a set rather than a path.";
        };

        # dinix writes to these six itself. A freeform attribute cannot hold a
        # value derived from config: the freeform merge forces every freeform
        # value to decide which attributes exist, so such a value would be its
        # own input. Declaring them keeps them lazy. They behave exactly as the
        # freeform ones do otherwise.
        depends-on = mkDinitListOption { };
        waits-for = mkDinitListOption { };
        after = mkDinitListOption { };
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

                  This does not make the directory. Such a directory is usually
                  a mounted volume, and the mount makes it. Add it to
                  {option}`dirs` as well if it needs making and owning.
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
            # text and envFileText are this rendering; dinix holds settings
            # dinit never sees; env-file is rendered below instead, because a
            # set becomes a file inside configDir and a relative reference.
            (filter (
              opt:
              !(builtins.elem opt.name [
                "text"
                "envFileText"
                "dinix"
                "env-file"
              ])
              && opt.value != null
            ))
          ];
          # @include and friends are directives, not assignments.
          toKV =
            settingName: value:
            if hasPrefix "@" settingName then
              "${settingName} ${toStringPlus value}"
            else
              "${settingName} = ${toStringPlus value}";

          # Consolidated, a description lives in configDir/services, so
          # ../env/<name> reaches configDir/env/<name>. dinit-service(5): a
          # relative env-file resolves against the directory holding the
          # description. Split, each env-file is its own store path.
          envFileLine =
            if config.env-file == null then
              [ ]
            else if config.envFileText == null then
              [ "env-file = ${toString config.env-file}" ]
            else if topConfig.consolidateConfig then
              [ "env-file = ../env/${name}" ]
            else
              [ "env-file = ${pkgs.writeText "env-file-${name}" config.envFileText}" ];
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

          # boot starts dinix-init and the critical services together, so a
          # hard dependency on dinix-init would not order them. after does.
          after = mkBefore (
            lib.optional (
              needsInit
              && !(builtins.elem name [
                "dinix-init"
                "boot"
              ])
            ) "dinix-init"
          );

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

          envFileText =
            if config.env-file != null && config.env-file.enable or false then config.env-file.text else null;

          text = concatLines (
            envFileLine
            ++ (pipe settings [
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

    dirs = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              path = mkOption {
                type = types.str;
                default = name;
                description = "The directory to make. Defaults to the attribute name.";
              };
              mode = mkOption {
                type = types.str;
                default = "0755";
                description = "Octal permissions for the directory itself.";
              };
              uid = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = ''
                  Numeric owner, or null to leave it alone.

                  Numeric rather than a name on purpose: this runs before the
                  services do, so the user database may not be in place yet and
                  a name would be a lookup that cannot be relied on. Setting an
                  owner at all needs root.
                '';
              };
              gid = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "Numeric group, or null to leave it alone. See uid.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Directories to make before any service starts, keyed by path.

        A Nix build cannot chown, so a directory that needs an owner or a mode
        has to be made at startup. {option}`initPackage` does that and nothing
        else: it has no way to run a program, which is why the image needs no
        shell.

        Setting this adds a `dinix-init` service that the boot service depends
        on, so a directory that cannot be made stops the container rather than
        letting a service start without it.
      '';
    };

    mustExist = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              path = mkOption {
                type = types.str;
                default = name;
                description = "The path that has to be there already.";
              };
              kind = mkOption {
                type = types.enum [
                  "any"
                  "dir"
                  "file"
                ];
                default = "dir";
                description = "What it has to be.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Paths that must already exist before any service starts, keyed by path.
        Nothing is created; this only checks, and stops the container when the
        check fails.

        This is for what a volume is supposed to provide. An unmounted volume
        otherwise shows up as whichever service happens to touch the path
        first, failing in its own vocabulary. Checking here names the path and
        says nothing created it, before anything else runs.

        Checked before {option}`dirs` is made.
      '';
    };

    consolidateConfig = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to put everything dinix generates in one store path
        ({option}`configDir`) rather than one path per piece.

        On, because a container image built from a Nix closure usually gets a
        layer per store path, and the six or so paths dinix would otherwise add
        are six layers holding bytes that all change together. Image formats
        have a layer ceiling, and these are not worth spending it on.

        Off is the right setting where store paths are not layers, such as a
        runtime that mounts the closure directly. Then each piece is its own
        path, and a change to one service does not rebuild the rest.
      '';
    };

    configDir = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        Every file dinix generates, in one store path.

        ```
        services/<name>   service descriptions
        env/<name>        per-service environment files
        env-file          the environment file dinit itself reads
        init.spec         the directories and checks for dinix-init
        etc/              passwd, group, shadow, nsswitch.conf
        var/empty         for daemons that want it
        ```

        One path rather than several because a container image built from a Nix
        closure usually gets a layer per store path. Splitting the same bytes
        over six paths spends six layers on them, and image formats have a
        layer ceiling worth saving for things that change independently. These
        do not: every file here is rewritten whenever any service changes.

        A service description refers to its environment file as `../env/<name>`,
        which dinit resolves against the directory holding the description.
        That keeps the reference inside this path instead of pointing at
        another one.
      '';
    };

    initPackage = mkOption {
      type = types.package;
      default = pkgs.callPackage ./dinix-init/package.nix { };
      description = ''
        The helper that makes {option}`dirs`. Statically linked and about
        500 KiB in a single store path with no dependencies.
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
          dinitPackage = mkOption {
            type = types.package;
            description = "package, with the shutdown tools removed if asked for.";
          };
          initSpecText = mkOption {
            type = types.str;
            description = "The checks and dirs, rendered for dinix-init.";
          };
          initSpecPath = mkOption {
            type = types.str;
            description = "Where that spec ends up.";
          };
          envFileText = mkOption {
            type = types.nullOr types.str;
            description = "The top-level env-file text, when it is a set rather than a path.";
          };
          envFilePath = mkOption {
            type = types.nullOr types.str;
            description = "Where dinit's own env-file ends up, or null when there is none.";
          };
          servicesDir = mkOption {
            type = types.str;
            description = "The directory holding one file per service.";
          };
          etcFiles = mkOption {
            type = types.attrsOf types.str;
            description = "The user database, as relative path to content.";
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
    services.dinix-init = mkIf needsInit {
      type = "scripted";
      command = "${getExe config.initPackage} ${config.internal.initSpecPath}";
      dinix.log = "console";
    };

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
        # A hard dependency, so a directory that cannot be made, or a mount
        # that is not there, stops the container instead of letting a service
        # start without it.
        depends-on = critical ++ lib.optional needsInit "dinix-init";
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

      initSpecText = concatLines (
        [ "# Generated by dinix. See dinix-init/src/spec.rs." ]
        # Checks first: a missing mount should be reported before anything is
        # made on top of it.
        ++ (lib.mapAttrsToList (
          _: required:
          lib.concatStringsSep "\t" [
            "must-exist"
            required.path
            required.kind
          ]
        ) config.mustExist)
        ++ (lib.mapAttrsToList (
          _: dir:
          lib.concatStringsSep "\t" [
            "dir"
            dir.path
            dir.mode
            (if dir.uid == null then "-" else toString dir.uid)
            (if dir.gid == null then "-" else toString dir.gid)
          ]
        ) config.dirs)
      );

      envFileText =
        if config.env-file != null && config.env-file.enable or false then config.env-file.text else null;

      # Where each generated file ends up. Consolidated, all of it is inside
      # configDir; split, each piece is its own store path.
      envFilePath =
        if config.env-file == null then
          null
        else if config.internal.envFileText == null then
          toString config.env-file
        else if config.consolidateConfig then
          "${config.configDir}/env-file"
        else
          toString (pkgs.writeText "env-file" config.internal.envFileText);

      initSpecPath =
        if config.consolidateConfig then
          # The dinix-init service description lives in configDir and has to
          # name a file in configDir, which no Nix expression can do: the path
          # is not known until the derivation is built. The builder substitutes
          # this for $out once the files are written.
          "@configDir@/init.spec"
        else
          toString (pkgs.writeText "dinix-init.spec" config.internal.initSpecText);

      servicesDir =
        if config.consolidateConfig then
          "${config.configDir}/services"
        else
          toString (
            writeFiles "dinix-services" (lib.mapAttrs' (
              serviceName: service: lib.nameValuePair serviceName service.text
            ) config.services) (checkCommand ".")
          );

      envfileArg = optionalString (
        config.internal.envFilePath != null
      ) "--env-file ${config.internal.envFilePath}";

      checkArgs = lib.concatStringsSep " " (
        [ "--services-dir ${config.internal.servicesDir}" ]
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

    };

    configDir =
      writeFiles "dinix-config"
        (
          (lib.mapAttrs' (
            serviceName: service: lib.nameValuePair "services/${serviceName}" service.text
          ) config.services)
          // (lib.concatMapAttrs (
            serviceName: service:
            lib.optionalAttrs (service.envFileText != null) {
              "env/${serviceName}" = service.envFileText;
            }
          ) config.services)
          // lib.optionalAttrs (config.internal.envFileText != null) {
            "env-file" = config.internal.envFileText;
          }
          // {
            "init.spec" = config.internal.initSpecText;
          }
          // config.internal.etcFiles
        )
        (
          ''
            # grep exits 1 when nothing matches, which is the ordinary case:
            # only a service that has to name this very path uses the marker.
            grep --recursive --files-with-matches --null @configDir@ "$out" \
              | xargs --null --no-run-if-empty sed --in-place "s|@configDir@|$out|g" \
              || true
          ''
          + checkCommand "services"
        );

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
