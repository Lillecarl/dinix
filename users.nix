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
          apply = toString;
        };
        gid = lib.mkOption {
          type = lib.types.int;
          apply = toString;
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
          apply = (x: if lib.isDerivation x then lib.getExe x else x);
        };
        text = lib.mkOption {
          type = lib.types.str;
        };
      };
      config.text = "${config.name}:${config.password}:${config.uid}:${config.gid}:${config.comment}:${config.homeDir}:${config.shell}";
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
          apply = toString;
        };
        users = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        text = lib.mkOption {
          type = lib.types.str;
        };
      };
      config.text = "${config.name}:x:${config.gid}:${lib.concatStringsSep "," config.users}";
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
    enable = lib.mkEnableOption "users";
    users = lib.mkOption {
      type = lib.types.attrsOf usertype;
      default = { };
    };
    groups = lib.mkOption {
      type = lib.types.attrsOf grouptype;
      default = { };
    };
  };
  config.internal.usersInstallScript = lib.mkIf config.users.enable (
    let
      users = lib.pipe config.users.users [
        lib.attrValues
        (lib.sort (x: y: x.uid < y.uid))
      ];
      groups = lib.pipe config.users.groups [
        lib.attrValues
        (lib.sort (x: y: x.gid < y.gid))
      ];
      install = pkgs.symlinkJoin {
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
    in
    pkgs.writeScriptBin "usergroupinstall" # bash
      ''
        #! ${pkgs.runtimeShell}
        export PATH=${
          lib.makeBinPath [
            pkgs.rsync
            pkgs.coreutils
          ]
        }:$PATH

        rsync --archive ${install}/ /
        ${lib.concatLines (
          map (user: ''
            mkdir --parents ${user.homeDir}
            chown -R ${user.name} ${user.homeDir}
          '') (lib.attrValues config.users.users)
        )}
      ''
  );
}
