{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.openssh;

  inherit (lib)
    concatLines
    getExe'
    mkDefault
    mkIf
    mkOption
    optionalAttrs
    types
    ;

  # sshd_config is "Keyword value", one per line. A keyword dinit may repeat,
  # HostKey and Port among them, takes a list here and becomes one line each.
  renderValue =
    value:
    if value == true then
      "yes"
    else if value == false then
      "no"
    else
      toString value;

  settingsText = concatLines (
    lib.flatten (
      lib.mapAttrsToList (
        keyword: value:
        map (one: "${keyword} ${renderValue one}") (if builtins.isList value then value else [ value ])
      ) cfg.settings
    )
  );

  generatedKeys = map (
    keyType: "${cfg.generateHostKeys.dir}/ssh_host_${keyType}_key"
  ) cfg.generateHostKeys.keyTypes;

  hostKeys = cfg.hostKeys ++ lib.optionals cfg.generateHostKeys.enable generatedKeys;

  ports =
    let
      value = cfg.settings.Port or null;
    in
    if value == null then
      [ ]
    else if builtins.isList value then
      value
    else
      [ value ];

  privilegedPorts = builtins.filter (port: lib.toInt (toString port) < 1024) ports;

  # sshd exits when it can load no host key, and says so in terms of the key
  # it looked for rather than of the configuration that named none.
  checkedSettings = lib.pipe settingsText [
    (lib.throwIf (hostKeys == [ ]) ''
      openssh.enable is set but there are no host keys. Either name the files a
      volume provides in openssh.hostKeys, or set
      openssh.generateHostKeys.enable to make them at startup.
    '')
    (lib.throwIf (cfg.rootless && privilegedPorts != [ ]) ''
      openssh.rootless is set, so sshd cannot bind port ${
        lib.concatMapStringsSep ", " toString privilegedPorts
      }. Only root may bind below 1024. Set openssh.settings.Port to a port
      above it, and map it from outside the container.
    '')
  ];

  # The description cannot name configDir, because configDir is built from the
  # descriptions. The builder substitutes the marker for $out. See
  # internal.initSpecPath, which has the same problem.
  configPath =
    if config.consolidateConfig then
      "@configDir@/etc/ssh/sshd_config"
    else
      toString (pkgs.writeText "sshd_config" checkedSettings);
in
{
  options.openssh = {
    enable = lib.mkEnableOption "an sshd service";

    package = mkOption {
      type = types.package;
      default = pkgs.openssh;
      description = "The OpenSSH package to run and to take `ssh-keygen` from.";
    };

    rootless = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether sshd runs as an ordinary user rather than as root.

        sshd decides this by its own uid, not by configuration, so this option
        tells dinix which of two shapes to render. Measured against OpenSSH
        10.5p1 by running both:

        - **A rootless sshd serves one account: its own.** It cannot change
          uid, so it accepts the login and then exits with "Failed to set uids"
          for any other user. The client sees the connection reset.
        - It needs no privilege separation. dinix therefore writes no `sshd`
          account and does not make `/var/empty`; sshd asks for neither when
          its uid is not 0.
        - **It cannot bind below port 1024**, so the default port becomes 2222.
          dinix refuses a privileged port here rather than letting sshd fail at
          startup.
        - A host key it does not own escapes the mode check, because sshd only
          checks a key that belongs to the user running it. A store path is
          owned by root, so a rootless sshd loads one that a root sshd
          refuses. **That is not a reason to put a key in the store**, which
          publishes it to every process on the host.

        This is the shape for a container that must not run as root, and the
        cost is that it serves one account.
      '';
    };

    hostKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Host key files a volume provides, in preference order. Each one also
        becomes a {option}`mustExist` check, so a volume that is not mounted
        stops the container with the path in the message rather than letting
        sshd report a key it cannot read.

        **The mode has to be 0400 or 0600.** sshd checks a private key it
        opens when the file belongs to the user running sshd, which in a
        container is root and so is the file. A Kubernetes secret arrives 0644
        unless `defaultMode` says otherwise, and every Nix store path is 0444,
        so neither works: sshd prints "UNPROTECTED PRIVATE KEY FILE" and
        ignores the key. Measured against OpenSSH 10.5p1, `authfile.c`.

        A key is a secret, so the store is not a place to keep one.
      '';
    };

    generateHostKeys = {
      enable = lib.mkEnableOption "making host keys at startup with `ssh-keygen -A`";

      root = mkOption {
        type = types.str;
        default = "/run/sshd";
        description = ''
          Where `ssh-keygen -A` writes, as the `-f` prefix it takes.

          **It is a prefix, not a directory.** ssh-keygen appends the built-in
          path to it, so keys land in `<root>/etc/ssh/` and not in `<root>`.
          {option}`generateHostKeys.dir` is that directory, and dinix makes it.

          The default is under `/run`, which a container usually has as a
          writable volume. On a volume that keeps nothing the host identity
          changes every restart, and a client that remembers the old one
          refuses to connect. Name a volume that persists where that matters.
        '';
      };

      dir = mkOption {
        type = types.str;
        default = "${cfg.generateHostKeys.root}/etc/ssh";
        readOnly = true;
        description = "Where the generated keys end up. dinix makes this directory.";
      };

      keyTypes = mkOption {
        type = types.listOf types.str;
        default = [ "ed25519" ];
        description = ''
          Which of the generated keys sshd is told about, as `HostKey` lines.

          `ssh-keygen -A` makes one key of every type the package was built
          with and takes no say in it, so this names the ones to use rather
          than the ones to make. All four together measured 0.7 s.
        '';
      };
    };

    uid = mkOption {
      type = types.int;
      default = 22;
      description = ''
        Numeric id for the `sshd` account, which holds no privileges and owns
        nothing.

        The name is not a choice: `SSH_PRIVSEP_USER` is compiled into sshd and
        nixpkgs leaves it at `sshd`. **sshd exits when the account is missing**
        and it runs as root, which is why dinix writes it rather than leaving
        it to the consumer. {option}`openssh.rootless` needs no such account,
        and then this is not used.
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 22;
      description = "Numeric id for the `sshd` group. See {option}`openssh.uid`.";
    };

    settings = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.bool
          types.int
          types.str
          (types.listOf (types.either types.int types.str))
        ]
      );
      default = { };
      description = ''
        sshd_config, as one attribute per keyword. See SSHD_CONFIG(5).

        A keyword that may appear more than once, `HostKey` and `Port` among
        them, takes a list and becomes one line for each element. A boolean
        becomes `yes` or `no`.
      '';
    };
  };

  config = mkIf cfg.enable {
    openssh.settings = {
      HostKey = mkDefault hostKeys;
      Port = mkDefault (if cfg.rootless then 2222 else 22);
      # sshd writes a pid file even with -D, and a container root filesystem
      # is usually read-only. Nothing here reads it: dinit is the supervisor.
      PidFile = mkDefault "none";
      # nixpkgs builds with PAM, and a container has no PAM configuration.
      UsePAM = mkDefault false;
      # Every account dinix writes has a locked password, so this could only
      # ever fail.
      PasswordAuthentication = mkDefault false;
      Subsystem = mkDefault "sftp ${cfg.package}/libexec/sftp-server";
    };

    # sshd calls getpwnam for the account that logs in, and fails the login
    # when it is missing, so the database has to be there either way.
    users.enable = true;
    users.users = optionalAttrs (!cfg.rootless) {
      sshd = {
        inherit (cfg) uid gid;
        comment = "Privilege separation user for sshd";
        homeDir = "/var/empty";
        shell = "/sbin/nologin";
      };
    };
    users.groups = optionalAttrs (!cfg.rootless) { sshd.gid = cfg.gid; };

    dirs =
      optionalAttrs (!cfg.rootless) {
        # sshd chroots its unprivileged process here and checks the directory
        # first: it must be a directory, owned by root, and not writable by
        # group or others. A Kubernetes emptyDir and a podman --tmpfs both
        # arrive 1777, which fails that check, so the mode is set rather than
        # assumed. Measured against OpenSSH 10.5p1, sshd.c.
        "/var/empty" = {
          mode = "0755";
          uid = 0;
          gid = 0;
        };
      }
      // optionalAttrs cfg.generateHostKeys.enable {
        # ssh-keygen -A opens the key files directly and makes no directory.
        # No owner when rootless: only root may chown, and the directory
        # already belongs to whoever dinit runs as.
        ${cfg.generateHostKeys.dir} = {
          mode = "0700";
          uid = if cfg.rootless then null else 0;
          gid = if cfg.rootless then null else 0;
        };
      };

    mustExist = lib.listToAttrs (map (path: lib.nameValuePair path { kind = "file"; }) cfg.hostKeys);

    internal.etcFiles = optionalAttrs config.consolidateConfig {
      "etc/ssh/sshd_config" = checkedSettings;
    };

    services.sshd = {
      type = "process";
      # -e sends the log to standard error, which is what dinix.log = "console"
      # then carries. Without it sshd talks to a syslog no container has.
      command = "${getExe' cfg.package "sshd"} -D -e -f ${configPath}";
      depends-on = lib.optional cfg.generateHostKeys.enable "sshd-keygen";
      # A service boot neither depends on nor waits for never starts at all,
      # so enabling this module has to attach sshd to boot. false is the
      # attachment that cannot surprise: sshd starts, and it can die and
      # restart without taking the container with it. Set it to true where
      # sshd is the reason the container exists.
      dinix.critical = mkDefault false;
    };

    services.sshd-keygen = mkIf cfg.generateHostKeys.enable {
      type = "scripted";
      # -A makes one key of every type that has none, so this is a plain exec
      # with no shell and it is safe to run again.
      command = "${getExe' cfg.package "ssh-keygen"} -A -f ${cfg.generateHostKeys.root}";
      dinix.log = "console";
    };
  };
}
