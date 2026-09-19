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
            The shadow line for this account, always with a locked password.

            There is deliberately no option to set a password hash. Everything
            dinix renders goes into the Nix store, and the store is readable by
            every user and every process on the host. A hash there is a hash
            published. Mount a real shadow file over this one if an account
            has to be able to log in.
          '';
        };
      };
      config = {
        text = "${config.name}:${config.password}:${toString config.uid}:${toString config.gid}:${config.comment}:${config.homeDir}:${config.shell}";
        # login:password:lastchange:min:max:warn:inactive:expire:reserved.
        # "!" is a locked password: no hash can match it.
        shadowText = "${config.name}:!:1::::::";
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
        Whether the container wrapper copies the user database into the root
        filesystem before starting dinit.

        Off by default, because a container root filesystem is usually
        read-only, and because a volume mounted over /etc hides the
        /etc/hosts and /etc/resolv.conf the runtime puts there, which takes
        out name resolution. Mount the files in {option}`users.files`
        individually instead.

        Turning this on puts a shell, rsync and coreutils in the closure of
        {option}`containerWrapper`, which is otherwise a plain binary
        wrapper.
      '';
    };
    files = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        The user database as a store path, holding `etc/passwd`, `etc/group`,
        `etc/shadow`, `etc/nsswitch.conf` and an empty `var/empty`.

        Mount these into a container one file at a time. A whole-directory
        mount over /etc hides what the runtime puts there.

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
    users.files =
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
      # Real files rather than a symlinkJoin. These get mounted one at a time,
      # and a bind mount of a symlink is not the file it points at.
      pkgs.runCommand "usergrpnss"
        {
          passAsFile = [
            "passwd"
            "group"
            "shadow"
            "nsswitch"
          ];
          passwd = lib.concatLines (map (user: user.text) users);
          group = lib.concatLines (map (group: group.text) groups);
          shadow = lib.concatLines (map (user: user.shadowText) users);
          nsswitch = "hosts: files dns\n";
        }
        ''
          mkdir --parents $out/etc $out/var/empty
          cp "$passwdPath" $out/etc/passwd
          cp "$groupPath" $out/etc/group
          cp "$shadowPath" $out/etc/shadow
          cp "$nsswitchPath" $out/etc/nsswitch.conf
        '';
    # Nix normalises store permissions to r--r--r--, so shadow cannot be made
    # unreadable here. That is why it never holds a hash.

    internal.usersInstallScript = lib.mkIf (config.users.enable && config.users.installAtRuntime) (
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
    );
  };
}
