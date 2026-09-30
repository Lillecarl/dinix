# The dinix instance the integration check runs. Its own expression so the
# test tree stands alone and dev.nix only has to point at it.
{
  pkgs ? import <nixpkgs> { },
  modules ? [ ./real-dinit.nix ],
}:
import ../.. {
  inherit pkgs modules;
}
