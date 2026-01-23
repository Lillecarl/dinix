{
  pkgs ? import <nixpkgs> { },
  modules ? [ ./demo.nix ],
}:
let
  inherit (pkgs) lib;

  eval = lib.evalModules {
    modules = [
      ./options.nix
    ]
    ++ modules;

    specialArgs = {
      inherit pkgs;
    };
  };
in
{
  inherit pkgs lib eval;
  inherit (eval) options config;
}
