{
  pkgs ? import <nixpkgs> { },
  modules ? [ ./config.nix ],
}:
let
  lib = pkgs.lib;

  eval = lib.evalModules {
    modules = [
      ./options.nix
    ]
    ++ modules;

    specialArgs = { inherit pkgs; };
  };
in
{
  inherit pkgs lib eval;
  inherit (eval) options config;
}
