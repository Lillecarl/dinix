# A collection that runs nixpkgs' own php-fpm modular service, unmodified.
#
# `php.services.default` is the module in
# pkgs/development/interpreters/php/service.nix, and it knows nothing of dinit.
# That is the point: dinix runs it as it is, the way the `modular` collection
# runs nixpkgs' python-http-server. dinix's own port lives in
# services/phpfpm.nix and offers more; this one measures what the upstream
# module can do here.
#
# Two limits show in what this collection does not say, and both are in issue
# #15:
#
#   - The pool listens on TCP. `listen` is written into a generated
#     configuration file, so a path in it is fixed when the file is generated,
#     and a socket under a state directory the manager names cannot be
#     expressed.
#   - The pool takes the package's own php.ini. The module has no option for
#     php.ini, and no `-c` argument to point at one.
{
  pkgs,
  config,
  lib,
  ...
}:
let
  fcgi = "${pkgs.fcgi}/bin/cgi-fcgi";
  env = "${pkgs.coreutils}/bin/env";

  port = 9001;

  # See the phpfpm collection for why the environment is emptied first.
  probe = address: "${env} -i ${fcgi} -bind -connect ${address}";
in
{
  system.services.php-upstream = {
    imports = [ pkgs.php.services.default ];

    php-fpm.settings.www = {
      listen = port;
      pm = "ondemand";
      "pm.max_children" = 1;
      # A php-fpm master running as root refuses to start without a pool user.
      # Unprivileged it ignores both directives with a warning, so one value
      # serves every mode. See services/phpfpm.nix.
      user = "nobody";
      group = "nogroup";
    };

    # The dinit tree dinix adds to every modular service. The upstream module
    # sets nothing here, so the collection says who the master runs as, exactly
    # as it does for dinix's own port.
    dinit.service.run-as = lib.mkIf config.privileged "nobody";
    dinit.service.dinix.critical = true;
  };

  collection = {
    packages = [
      pkgs.coreutils
      pkgs.fcgi
    ];

    checks = [
      {
        # Only the PHP SAPI answering over FastCGI emits this header, and
        # nixpkgs' php.ini leaves expose_php on.
        name = "the upstream php-fpm module answers over FastCGI under dinit";
        command = probe "127.0.0.1:${toString port}";
        expect = "X-Powered-By: PHP/";
      }
    ];
  };
}
