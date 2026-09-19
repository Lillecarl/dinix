{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.caCertificates;

  inherit (lib)
    mkIf
    mkOption
    types
    ;
in
{
  options.caCertificates = {
    enable = lib.mkEnableOption "a CA bundle, named to every service by environment";

    package = mkOption {
      type = types.package;
      default = pkgs.cacert;
      description = "The package holding the bundle. Nothing reaches the closure until this is enabled.";
    };

    file = mkOption {
      type = types.str;
      default = "${cfg.package}/etc/ssl/certs/ca-bundle.crt";
      readOnly = true;
      description = ''
        The bundle itself.

        Mount this at the path a program insists on when it has no way to be
        told. Go, curl, git and anything using OpenSSL read the environment
        first, so they need no mount.
      '';
    };

    variables = mkOption {
      type = types.listOf types.str;
      default = [
        "SSL_CERT_FILE"
        "NIX_SSL_CERT_FILE"
        "CURL_CA_BUNDLE"
        "GIT_SSL_CAINFO"
      ];
      description = ''
        Which environment variables name the bundle. Each gets
        {option}`caCertificates.file`.

        `SSL_CERT_FILE` is the one OpenSSL itself reads, and covers most
        programs. `NIX_SSL_CERT_FILE` is what the OpenSSL in nixpkgs and Nix
        itself read. The other two are for programs that ignore both.

        Add `REQUESTS_CA_BUNDLE` for Python, or any other name a program of
        yours reads. Nothing here checks the names.
      '';
    };
  };

  config = mkIf cfg.enable {
    # A container built from a Nix closure has no /etc/ssl, so a program that
    # falls back to a compiled-in path finds nothing and reports a certificate
    # error rather than a missing file. Naming the bundle by environment
    # reaches every service, needs no mount, and needs no writable filesystem.
    env-file.variables = lib.genAttrs cfg.variables (_: cfg.file);
  };
}
