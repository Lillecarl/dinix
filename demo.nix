{
  config,
  lib,
  pkgs,
  ...
}:
let
  htmlPackage = pkgs.writeTextFile {
    name = "nginx-static-html";
    destination = "/index.html";
    text = # html
      ''
        <!DOCTYPE html>
        <html>
        <head><title>Hello</title></head>
        <body><h1>Hello World</h1></body>
        </html>
      '';
  };
  nginxConfig =
    pkgs.writeText "nginxConfig" # nginx
      ''
        daemon off;
        pid /tmp/nginx.pid;
        error_log /dev/stderr;
        events {}
        http {
            access_log /dev/stdout;
            server {
                listen 8080;
                location / {
                    root ${htmlPackage};
                    index index.html;
                }
            }
        }
      '';
in
{
  config = {
    env-file = {
      variables = {
        "DINITENV" = "DINITENV";
      };
    };
    services.boot = {
      type = "internal";
      depends-on-d = [ "nginx" ];
    };
    services.nginx = {
      type = "process";
      command = "${lib.getExe pkgs.nginx} -c ${nginxConfig} -e /dev/stderr";
      restart = true;
      options = [ "shares-console" ];
      include-opt = "/doesnt/exist";
      env-file = {
        variables = {
          "NGINXENV" = "NGINXENV";
        };
      };
    };
  };
}
