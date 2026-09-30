# A container image for nginx serving a static page.
#
# The same module as examples/services/nginx.nix, with the image around it. The
# page is a store path, so nginx reads it from the image with nothing to make.
#
#   nix run --file ./dev.nix containers.nginx.copyToPodman
#   podman run --rm -it -p 8080:8080 dinix-example-nginx:latest
{ pkgs ? import <nixpkgs> { } }:
let
  site = pkgs.runCommand "dinix-nginx-container-site" { } ''
    mkdir $out
    echo '<h1>served by dinix, in a container</h1>' > $out/index.html
  '';
in
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, lib, ... }: {
      system.services.nginx = {
        imports = [
          (lib.modules.importApply ../../services/nginx.nix { inherit (pkgs) nginx mailcap; })
        ];
        nginx = {
          port = 8080;
          root = "${site}";
        };
        dinit.service.dinix.critical = true;
      };
    })
  ];
}
