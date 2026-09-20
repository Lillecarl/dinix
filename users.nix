{
  config,
  pkgs,
  lib,
  ...
}:
let
  usertype = lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
        };
        password = lib.mkOption {
          type = lib.types.str;
          default = "x";
        };
        uid = lib.mkOption {
          type = lib.types.int;
        };
        gid = lib.mkOption {
          type = lib.types.int;
        };
        comment = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        homeDir = lib.mkOption {
          type = lib.types.path;
          default = "/home/${name}";
        };
        shell = lib.mkOption {
          type = lib.types.either lib.types.path lib.types.package;
          default = "/bin/sh";
          apply = x: if lib.isDerivation x then lib.getExe x else x;
        };
        text = lib.mkOption {
          type = lib.types.str;
          description = "The passwd line for this account.";
        };
        shadowText = lib.mkOption {
          type = lib.types.str;
          description = ''
            The shadow line for this account. No password can ever match it.

            There is deliberately no option to set a password hash. Everything
            dinix renders goes into the Nix store, and the store is readable by
            every user and every process on the host. A hash there is a hash
            published. Mount a real shadow file over this one if an account
            has to log in with a password.

            The field is `*` rather than `!`, which is what `passwd -l` writes.
            Both refuse every password, but OpenSSH on Linux reads a leading
            `!` as a locked account and then refuses the account outright,
            key login included, whenever PAM is off. Measured against OpenSSH
            10.5p1.
          '';
        };
      };
      config = {
        text = "${config.name}:${config.password}:${toString config.uid}:${toString config.gid}:${config.comment}:${config.homeDir}:${config.shell}";
        # login:password:lastchange:min:max:warn:inactive:expire:reserved.
        #
        # "*" and not "!", although both mean no password can match. On Linux
        # OpenSSH compiles in LOCKED_PASSWD_PREFIX = "!" and nothing else, so
        # with UsePAM off it reads "!" as a locked account and refuses every
        # login, key or not: "User root not allowed because account is locked".
        # "*" matches none of its patterns and no crypt output, so a key login
        # works and a password login still cannot. Measured against OpenSSH
        # 10.5p1, platform.c.
        shadowText = "${config.name}:*:1::::::";
      };
    }
  );
  grouptype = lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
        };
        gid = lib.mkOption {
          type = lib.types.int;
        };
        users = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        text = lib.mkOption {
          type = lib.types.str;
        };
      };
      config.text = "${config.name}:x:${toString config.gid}:${lib.concatStringsSep "," config.users}";
    }
  );
in
{
  imports = [
    {
      # Defaults for root and nobody user
      config.users = lib.mapAttrsRecursive (n: v: lib.mkDefault v) {
        users.root = {
          uid = 0;
          gid = 0;
          comment = "System administrator";
          homeDir = "/root";
        };
        groups.root = {
          name = "root";
          gid = 0;
        };
        users.nobody = {
          uid = 65534;
          gid = 65534;
          comment = "Unprivileged account (don't use!)";
        };
        groups.nobody = {
          name = "nobody";
          gid = 65534;
        };
        # The same group under the other name it goes by. Programs compiled
        # for a distribution look up one or the other and exit when it is
        # missing: nginx asks for `nogroup` and dies with `getgrnam("nogroup")
        # failed`, while a Debian-built package asks for `nobody`. NixOS ships
        # user `nobody` with group `nogroup`, so both names at one gid is what
        # matches the world around it.
        groups.nogroup = {
          name = "nogroup";
          gid = 65534;
        };
      };
    }
  ];
  options.users = {
    enable = lib.mkEnableOption "a user database for this configuration";
    users = lib.mkOption {
      type = lib.types.attrsOf usertype;
      default = { };
      description = "Accounts to put in passwd, one attribute per account.";
    };
    groups = lib.mkOption {
      type = lib.types.attrsOf grouptype;
      default = { };
      description = "Groups to put in group, one attribute per group.";
    };
    installAtRuntime = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        How the user database reaches the container: by copying it into the
        root filesystem at startup, rather than by mounting it.

        Those are the two deliveries, and this picks between them. It is off by
        default because a container root filesystem is usually read-only, and
        because a volume mounted over /etc hides the /etc/hosts and
        /etc/resolv.conf the runtime puts there, which takes out name
        resolution. The other delivery is to mount the files in
        {option}`users.files` one at a time, which is what a read-only or
        non-root container has to do.

        Setting this without {option}`users.enable` is an error rather than a
        silent no-op.

        Turning this on puts a shell, rsync and coreutils in the closure of
        {option}`containerWrapper`, which is otherwise a plain binary
        wrapper.
      '';
    };
    files = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        The store path holding the user database, as `etc/passwd`, `etc/group`,
        `etc/shadow` and `etc/nsswitch.conf`.

        This is {option}`configDir`, which carries the rest of the generated
        configuration as well. Mount the one file you want out of it, a file at
        a time: a whole-directory mount over /etc hides what the runtime puts
        there.

        A process that calls `getpwuid` on its own uid fails outright when the
        uid is absent from passwd, so the content matters even where nothing
        reads the file directly.

        Every account in `etc/shadow` is locked, and the file is world-readable
        because everything in the Nix store is. That is safe only because it
        holds no hashes. Do not replace it with one that does; mount the real
        file instead.
      '';
    };
  };

  config = {
    users.files = config.configDir;

    # Nix normalises store permissions to r--r--r--, so shadow cannot be made
    # unreadable. That is why it never holds a hash.
    internal.etcFiles =
      let
        users = lib.pipe config.users.users [
          lib.attrValues
          (lib.sort (x: y: x.uid < y.uid))
        ];
        groups = lib.pipe config.users.groups [
          lib.attrValues
          (lib.sort (x: y: x.gid < y.gid))
        ];
      in
      {
        "etc/passwd" = lib.concatLines (map (user: user.text) users);
        "etc/group" = lib.concatLines (map (group: group.text) groups);
        "etc/shadow" = lib.concatLines (map (user: user.shadowText) users);
        # Every database this file leaves out is a database glibc has no
        # source for. sshd then calls a real account an "invalid user",
        # because getpwnam found nothing to read.
        "etc/nsswitch.conf" = lib.concatLines [
          "passwd:    files"
          "group:     files"
          "shadow:    files"
          "hosts:     files dns"
          "services:  files"
        ];
      };

    internal.usersInstallScript = lib.mkIf config.users.installAtRuntime (
      lib.throwIf (!config.users.enable)
        "users.installAtRuntime is set but users.enable is not, so there is no user database to install."
        (
          pkgs.writeScriptBin "usergroupinstall" # bash
            ''
              #! ${pkgs.runtimeShell}
              export PATH=${
                lib.makeBinPath [
                  pkgs.rsync
                  pkgs.coreutils
                ]
              }:$PATH

              rsync --archive ${config.users.files}/ /
              ${lib.concatLines (
                map (user: ''
                  mkdir --parents ${user.homeDir}
                  chown -R ${user.name} ${user.homeDir}
                '') (lib.attrValues config.users.users)
              )}
            ''
        )
    );
  };
}
