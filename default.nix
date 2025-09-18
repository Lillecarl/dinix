let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;

  eval = lib.evalModules {
    modules = [
      ./options.nix
      ./config.nix
    ];

    specialArgs = { inherit pkgs; };
  };
in
{
  inherit pkgs lib eval;
  inherit (eval) options config;
}
