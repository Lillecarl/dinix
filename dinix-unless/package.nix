{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "dinix-unless";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  # Cargo's own `strip = true` does not survive buildRustPackage. See
  # dinix-init/package.nix.
  stripAllList = [ "bin" ];

  meta = {
    description = "Runs a program only when a marker path is absent, so a service initialises once without a shell";
    mainProgram = "dinix-unless";
    license = lib.licenses.mit;
  };
}
