# dinix

Create dinit configurations with the NixOS module system

## How to test
Clone & cd repo, run. Which will launch nginx on port 8080 echoing Hello World.
```
nix run --file . config.out.script -- --user
```
