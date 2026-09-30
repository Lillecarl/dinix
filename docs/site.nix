# The documentation site, assembled and built with Sphinx.
#
# The source tree is generated, not checked in. The guide is README.md, the
# porting notes are PORTING.md, the examples are examples/README.md, and the
# option page is rendered from options.nix itself. So the site cannot describe
# an option that no longer exists, and there is no generated file in the
# repository to go stale.
#
# The shape is solid-kubernetes': `stdenvNoCC.mkDerivation` running
# `sphinx-build -b html docs "$out" -W`. GitHub Pages serves the result; see
# .github/workflows/pages.yml.
{
  lib,
  stdenvNoCC,
  python3,
  # The rendered option reference. See ./default.nix.
  optionsCommonMark,
  readme,
  porting,
  examplesReadme,
  # `-W` turns Sphinx warnings into errors. A relative link that no longer
  # resolves is a warning, so this is the gate that keeps the guide honest.
  warningsAreErrors ? true,
}:
let
  pythonEnv = python3.withPackages (ps: [
    ps.sphinx
    ps.myst-parser
    ps.furo
  ]);

  # Appended to the guide so the other pages reach the sidebar. The README
  # keeps its own filename, so its relative `PORTING.md` link resolves to the
  # document of that name with no rewriting.
  toctree = ''
    ```{toctree}
    :hidden:

    Porting <PORTING>
    Examples <examples>
    All options <options>
    ```
  '';
in
stdenvNoCC.mkDerivation {
  pname = "dinix-docs";
  version = "0";

  dontUnpack = true;
  nativeBuildInputs = [ pythonEnv ];

  buildPhase = ''
    runHook preBuild

    mkdir -p docs

    cat ${./conf.py} > docs/conf.py

    {
      cat ${readme}
      printf '\n'
      cat <<'DINIX_EOF'
    ${toctree}
    DINIX_EOF
    } > docs/index.md

    cat ${porting} > docs/PORTING.md
    cat ${examplesReadme} > docs/examples.md

    # The whole option set on one page, from the same evaluation the checks
    # use. Every option is here whether or not a configuration sets it.
    {
      printf '# All options\n\n'
      printf 'Every option dinix declares, rendered from `options.nix` itself. The\n'
      printf 'guide introduces the ones a configuration usually sets.\n\n'
      cat ${optionsCommonMark}
    } > docs/options.md

    sphinx-build -b html docs "$out" \
      ${lib.optionalString warningsAreErrors "-W"}

    runHook postBuild
  '';

  dontInstall = true;
}