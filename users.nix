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
        };
      };
      config.text = "${config.name}:${config.password}:${toString config.uid}:${toString config.gid}:${config.comment}:${config.homeDir}:${config.shell}";
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
        `etc/nsswitch.conf` and an empty `var/empty`.

        Mount these into a container one file at a time. A whole-directory
        mount over /etc hides what the runtime puts there.

        A process that calls `getpwuid` on its own uid fails outright when the
        uid is absent from passwd, so the content matters even where nothing
        reads the file directly.
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
      pkgs.symlinkJoin {
        name = "usergrpnss";
        paths = [
          (pkgs.writeTextDir "etc/passwd" ''
            ${lib.concatLines (map (user: user.text) users)}
          '')
          (pkgs.writeTextDir "etc/group" ''
            ${lib.concatLines (map (group: group.text) groups)}
          '')
          (pkgs.writeTextDir "etc/nsswitch.conf" ''
            hosts: files dns
          '')
          (pkgs.runCommand "var-empty" { } ''
            mkdir -p $out/var/empty
          '')
        ];
      };

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
