{
  pkgs ? import <nixpkgs> { },
  modules ? [ ./config.nix ],
}:
let
  pkgs' = pkgs.extend (import ./overlay.nix);
  lib = pkgs'.lib;

  eval = lib.evalModules {
    modules = [
      ./options.nix
    ]
    ++ modules;

    specialArgs = { pkgs = pkgs'; };
  };
in
{
  pkgs = pkgs';
  inherit lib eval;
  inherit (eval) options config;
}
