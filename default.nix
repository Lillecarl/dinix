# Instantiating dinix answers one attribute per environment, because
# offering these modules means running them in every reasonable one. Each
# attribute is the same evaluation shape as always — `pkgs`, `lib`, `eval`,
# `options`, `config` — for the same modules plus one that sets
# {option}`mode`, which cascades into the configuration the mode needs: no
# dinix-init without a container, no run-as without privilege.
#
# Testing every output for every collection is what lets one configuration
# be depended on in all three: differences live in the evaluation, where a
# build either works or fails loudly, and never in what a driver does at
# runtime.
{
  pkgs ? import <nixpkgs> { },
  modules ? [ ./demo.nix ],
}:
let
  inherit (pkgs) lib;

  evalOnce = mode: {
    inherit pkgs lib;
    eval = lib.evalModules {
      modules = [
        ./options.nix
        { inherit mode; }
      ]
      ++ modules;

      specialArgs = {
        inherit pkgs;
      };
    };
  };

  withConfig =
    evaluated: evaluated // { inherit (evaluated.eval) options config; };
in
{
  rootContainer = withConfig (evalOnce "rootContainer");
  nobodyContainer = withConfig (evalOnce "nobodyContainer");
  noContainer = withConfig (evalOnce "noContainer");
}
