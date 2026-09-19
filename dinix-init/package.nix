{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "dinix-init";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  # The crate has no dependencies, so there is nothing to fetch and no hash to
  # keep in step.
  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Creates the directories a dinit service tree needs, and nothing else";
    mainProgram = "dinix-init";
    license = lib.licenses.mit;
  };
}
