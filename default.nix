{
  pkgs ? import <nixpkgs> { },
  modules ? [ ./demo.nix ],
}:
let
  pkgs' = pkgs.extend (import ./overlay.nix);
in
let
  pkgs = pkgs';
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
