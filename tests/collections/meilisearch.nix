# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# meilisearch is authored as a NixOS Modular Service. See
# services/meilisearch.nix and PORTING.md.
{ pkgs, config, lib, ... }:
let
  meilisearchService = lib.modules.importApply ../../services/meilisearch.nix {
    inherit (pkgs) meilisearch coreutils;
  };

  main = config.system.services.meilisearch-main.meilisearch;

  curl = "${pkgs.curl}/bin/curl";

  # The JSON body, not the status code: meilisearch answers both questions
  # with 200 and the answer is in the text.
  get =
    path:
    "${curl} -s http://127.0.0.1:${toString main.listenPort}${path}";
in
{
  system.services.meilisearch-main = {
    imports = [ meilisearchService ];
  };

  collection = {
    writable = [ main.dataDir ];

    packages = [ pkgs.curl ];

    checks = [
      {
        name = "meilisearch reports itself available";
        command = get "/health";
        expect = "available";
      }
      {
        name = "and answers for its version";
        command = get "/version";
        expect = "commitSha";
      }
    ];
  };
}
