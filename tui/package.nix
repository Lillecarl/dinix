# A developer output: the Textual TUI that drives a dinit through the control
# protocol client. Nothing in default.nix reaches this, so no Python enters a
# dinix container or an uncontained run.
{
  lib,
  python3Packages,
  dinitClient,
}:

python3Packages.buildPythonApplication {
  pname = "dinix-tui";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ python3Packages.hatchling ];
  dependencies = [
    python3Packages.anyio
    python3Packages.textual
    dinitClient
  ];

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];
  pythonImportsCheck = [ "dinix_tui" ];

  meta = {
    description = "A Textual TUI for dinit services managed by dinix";
    license = lib.licenses.mit;
    mainProgram = "dinix-tui";
  };
}
