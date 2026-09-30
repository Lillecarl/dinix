# A developer output: the AnyIO client for the dinit control socket.
#
# Nothing in default.nix reaches this, so no Python enters a dinix container
# or an uncontained run. Only the TUI and the test harness import it.
{
  lib,
  python3Packages,
}:

python3Packages.buildPythonPackage {
  pname = "dinit-client";
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
  dependencies = [ python3Packages.anyio ];

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];
  pythonImportsCheck = [ "dinit_client" ];

  meta = {
    description = "AnyIO client for the dinit control socket protocol";
    license = lib.licenses.mit;
  };
}
