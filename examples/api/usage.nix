# What `import ./dinix { modules = [ ... ]; }` returns, and what each attribute
# is for:
#
#   pkgs    the package set it was given.
#   lib     nixpkgs' library.
#   eval    the module-system result, when you want options or an extendModules.
#   options the option declarations.
#   config  the evaluated configuration:
#             config.configDir         every generated file, one store path
#             config.internal.servicesDir  the service descriptions
#             config.userWrapper       dinit --user, reading them from the store
#             config.containerWrapper  dinit as PID 1 of a container
#             config.tuiWrapper        dinit for a TUI-driven runtime
#
# Poke at it without running anything:
#
#   nix eval  --file ./examples/api/usage.nix config.configDir
#   nix build --file ./examples/api/usage.nix config.configDir
#   nix build --file ./examples/api/usage.nix config.containerWrapper
{ pkgs ? import <nixpkgs> { } }:
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, ... }: {
      services.greeting = {
        type = "process";
        command = pkgs.writeShellScript "greeting.sh" ''
          echo "hello from the api example"
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        dinix.log = "buffer";
        dinix.critical = false;
      };
    })
  ];
}
