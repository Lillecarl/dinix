# One evaluation, as the README promises: `pkgs`, `lib`, `eval`, `options`,
# `config`.
#
# {option}`mode` says which environment this configuration is for, and it is an
# ordinary option with a default — set it in `modules` like any other. An
# earlier version answered one attribute per mode instead, which made a
# consumer pick an attribute before it could reach `config` and broke every
# existing call site to save a caller three lines. Evaluating every mode is a
# test's job; `dev.nix` does it.
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
