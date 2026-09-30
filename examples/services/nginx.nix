# nginx, through the modular-service port in services/nginx.nix.
#
# The module writes one `server` block on `nginx.port` serving `nginx.root`,
# and takes more blocks through `nginx.httpConfig`. Everything the process
# writes goes under the state directory it runs with `-p`, and dinix-init makes
# that directory before it starts.
#
#   nix run --file ./dev.nix examples.services.nginx
#
# Then browse http://127.0.0.1:8080/.
{ pkgs ? import <nixpkgs> { } }:
let
  # Content to serve. A store path like any other, so nginx reads it without
  # anything being made.
  site = pkgs.runCommand "dinix-nginx-example-site" { } ''
    mkdir $out
    echo '<h1>served by dinix</h1>' > $out/index.html
  '';
in
import ../.. {
  inherit pkgs;
  modules = [
    ({ pkgs, lib, ... }: {
      privileged = false;

      system.services.nginx = {
        imports = [
          (lib.modules.importApply ../../services/nginx.nix { inherit (pkgs) nginx mailcap; })
        ];
        nginx = {
          port = 8080;
          root = "${site}";
        };
      };
    })
  ];
}
