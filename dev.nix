# Development entry point. Nothing in default.nix imports this, so nix2container
# never reaches a dinix consumer's closure.
#
# It exists to answer one question with a measurement rather than a guess: how
# many layers, and how many bytes, does a container image built from a dinix
# configuration actually cost?
#
#   nix run --file ./dev.nix report
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
    ;
}
