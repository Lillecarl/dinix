# Development entry point. Nothing in default.nix imports this, so neither
# nix2container nor a test harness reaches a dinix consumer's closure.
#
# It answers two questions with a measurement rather than a guess.
#
# How many layers, and how many bytes, does an image cost?
#
#   nix run --file ./dev.nix report
#
# And does a dinix container work when something other than this machine runs
# it? user-mode-nixos boots a guest, podman runs the image in it, and the test
# asserts against the running container.
#
#   nix build --file ./dev.nix containerTest rootlessTest   # in a build sandbox
#   nix run   --file ./dev.nix containerTest.run            # outside it
#
# Two of them, because sshd separates privileges or not according to its own
# uid, and dinix renders a different configuration for each.
#
{
  pkgs ? import <nixpkgs> { },
  modules ? [ ./demo.nix ],
  # Same revision nixidae pins, so the two agree.
  nix2container-src ? builtins.fetchGit {
    url = "https://github.com/nlewo/nix2container.git";
    rev = "b6ac40ef110c12ab1651fce5ea563f7837236439";
    allRefs = true;
  },
  # lib.nix is the door for a caller with its own guests and its own script,
  # and takes a package set. Going through default.nix instead would pull in
  # the nixidae umbrella, which resolves every source of that repository and
  # has nothing to say about this one.
  user-mode-nixos-src ? builtins.fetchGit {
    url = "https://github.com/Lillecarl/user-mode-nixos.git";
    rev = "136e93112f40e20c07aa6a334158543b63112971";
    allRefs = true;
  },
}:

let
  inherit (pkgs) lib;

  inherit (import nix2container-src { inherit pkgs; }) nix2container;

  # maxLayers turns on nix2container's automatic layering, which gives the
  # biggest store paths a layer each. That is the setting where a store path
  # costs a layer, and so the setting consolidateConfig is about. The default
  # of 1 puts the whole closure in a single layer and would measure nothing.
  imageFor =
    consolidate:
    let
      dinix = import ./. {
        inherit pkgs;
        modules = modules ++ [ { consolidateConfig = consolidate; } ];
      };
    in
    nix2container.buildImage {
      name = "dinix-${if consolidate then "consolidated" else "split"}";
      config.entrypoint = [ (lib.getExe dinix.config.containerWrapper) ];
      maxLayers = 100;
    };

  consolidated = imageFor true;
  split = imageFor false;

  uml = import (user-mode-nixos-src + "/lib.nix") { inherit pkgs; };

  # Made at build time and not reproducible, which is right here: the test
  # wants a key nothing else has, and Nix caches the derivation anyway.
  clientKey =
    pkgs.runCommand "dinix-test-key"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir --parents $out
        ssh-keygen -t ed25519 -N "" -C dinix-test -f $out/id_ed25519
        cp $out/id_ed25519.pub $out/authorized_keys
      '';

  /**
    One container test: an image from `extraModules`, and the guest that runs
    it.

    Two of these, because sshd decides by its own uid whether it separates
    privileges, and dinix renders a different configuration for each. One
    script drives both; `settings` carries what differs.
  */
  containerTestFor =
    {
      name,
      extraModules ? [ ],
      # The uid the container runs as, and the account sshd will serve.
      uid ? 0,
      podmanUser ? "",
    }:
    let
      dinix = import ./. {
        inherit pkgs;
        modules = [
          ./tests/container.nix
          { _module.args.clientKey = clientKey; }
        ]
        ++ extraModules;
      };

      image = nix2container.buildImage {
        inherit name;
        tag = "test";
        # sshd runs the login shell named in passwd, and then looks for the
        # command on a PATH of /usr/bin:/bin:/usr/sbin:/sbin, which it compiles
        # in. So an ssh container needs /bin/sh and a few tools whatever else it
        # carries; dinix's own services need none of it.
        copyToRoot = pkgs.buildEnv {
          name = "${name}-root";
          paths = [ pkgs.busybox ];
          pathsToLink = [ "/bin" ];
        };
        config.entrypoint = [ (lib.getExe dinix.config.containerWrapper) ];
        maxLayers = 100;
      };

      loginUser =
        lib.findFirst (account: account.uid == uid)
          (throw "no account in the test configuration has uid ${toString uid}")
          (lib.attrValues dinix.config.users.users);
    in
    uml.mkTest {
      inherit name;
      script = ./tests/openssh.py;
      nodes.node = {
        virtualisation.podman.enable = true;
        environment.systemPackages = [ pkgs.openssh ];
        boot.uml = {
          memory = "2048M";
          # The image unpacks into the guest's own filesystem rather than being
          # read out of the store, so the disk holds a copy of the closure. A
          # sparse file, so this costs nothing until it is used.
          diskSize = 8192;
        };
      };
      settings = {
        inherit uid podmanUser;
        loginUser = loginUser.name;
        copyToPodman = lib.getExe image.copyToPodman;
        imageRef = "${image.imageName}:${image.imageTag}";
        clientKey = "${clientKey}";
        configDir = "${dinix.config.configDir}";
        dinitctl = "${dinix.config.containerWrapper}/bin/dinitctl";
        port = dinix.config.openssh.settings.Port;
        caBundle = dinix.config.caCertificates.file;
        # /run holds dinit's control socket and the generated host keys.
        # /var/empty is sshd's privilege separation directory, which a rootless
        # sshd never looks at. /data is the volume mustExist asks for, and the
        # test runs the container a second time without it.
        mustExist = "/data";
        tmpfs = [
          "/run"
          "/data"
        ]
        ++ lib.optional (uid == 0) "/var/empty";
      };
    };

  containerTest = containerTestFor { name = "dinix-openssh"; };

  rootlessTest = containerTestFor {
    name = "dinix-openssh-rootless";
    extraModules = [ ./tests/rootless.nix ];
    uid = 1000;
    podmanUser = "1000:1000";
  };

  # buildImage's output is a JSON manifest naming every layer and the store
  # paths in it, so the count and the sizes come from the image itself rather
  # than from counting the closure by hand.
  report = pkgs.writeShellApplication {
    name = "dinix-image-report";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      summarise() {
        local name=$1 manifest=$2
        printf '%-14s %2d layers  %s\n' \
          "$name" \
          "$(jq '.layers | length' "$manifest")" \
          "$(numfmt --to=iec --suffix=B "$(jq '[.layers[].size] | add' "$manifest")")"
      }
      summarise consolidated ${consolidated}
      summarise split ${split}
      echo
      echo "layers in the consolidated image, largest first:"
      jq --raw-output '
        .layers
        | sort_by(-.size)
        | .[]
        | "  \(.size | tostring | .[0:9]) bytes  \(.paths[0].path // "?" | split("/") | last)"
      ' ${consolidated}
    '';
  };
in
{
  inherit
    consolidated
    split
    report
    nix2container
    uml
    clientKey
    containerTest
    rootlessTest
    ;
}
