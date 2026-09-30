# dinix's option reference, rendered from the doc comments in options.nix.
#
#   nix build --file ./dev.nix docs
#
# This is the solid-kubernetes pattern with the site stripped: `nixosOptionsDoc`
# walks an `options` tree and writes CommonMark, and `nixdoc` renders `/** */`
# comments from a library file. dinix has no library of its own -- `default.nix`
# returns nixpkgs' `lib` -- so the module options are the whole surface.
#
# The evaluation has `options` and no `config`, so a default that reads
# `config` would throw when the doc writer serialises it. Every default is
# forced under `tryEval` first and a thrower becomes a marker, which is what
# `environmentDependent` in solid-kubernetes/docs/options.nix also does.
{
  pkgs ? import <nixpkgs> { },
  modules ? [ ../demo.nix ],
}:
let
  inherit (pkgs) lib;

  dinix = import ./.. { inherit pkgs modules; };

  repoRoot = toString ./..;

  # `deepSeq` because the throw is usually inside a string interpolation or a
  # list element, not at the top, and `seq` alone reports success and then
  # fails later inside the JSON writer with no option name left to name.
  safely =
    value:
    let
      probed = builtins.tryEval (builtins.deepSeq value value);
    in
    if probed.success then
      { ok = probed.value; }
    else
      {
        marker = {
          _type = "literalMD";
          text = "*needs a configuration*";
        };
      };

  transformOptions =
    opt:
    opt
    // {
      # Repo-relative, so a declaration reads `options.nix` rather than an
      # absolute path that changes with the checkout. A `name` with no `url`
      # renders as plain text.
      declarations = map (
        decl:
        let
          s = toString decl;
        in
        {
          name = if lib.hasPrefix "${repoRoot}/" s then lib.removePrefix "${repoRoot}/" s else s;
        }
      ) opt.declarations;
    }
    // lib.optionalAttrs (opt ? default) (
      let
        r = safely opt.default;
      in
      if r ? ok then { default = r.ok; } else { default = r.marker; }
    )
    // lib.optionalAttrs (opt ? example) (
      let
        r = safely opt.example;
      in
      if r ? ok then { example = r.ok; } else { example = r.marker; }
    );

  doc = pkgs.nixosOptionsDoc {
    # `_module` is nixpkgs' own bookkeeping, not dinix's surface.
    options = builtins.removeAttrs dinix.eval.options [ "_module" ];
    inherit transformOptions;
    warningsAreErrors = false;
  };

  json = builtins.fromJSON (builtins.readFile "${doc.optionsJSON}/share/doc/nixos/options.json");
  needsConfig = builtins.filter (
    name: (json.${name}.default._type or "") == "literalMD"
  ) (builtins.attrNames json);
in
{
  inherit (doc) optionsCommonMark optionsJSON;

  # The number that says whether this approach holds for dinix: an option whose
  # default cannot be rendered without a configuration is documentation debt to
  # pay with `defaultText`, not a reason the pipeline is wrong.
  environmentDependent = {
    total = builtins.length (builtins.attrNames json);
    names = needsConfig;
  };
}
