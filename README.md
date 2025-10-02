# dinix

Create dinit configurations with the NixOS module system

## dinix -> dinit option mapping:
See [DINIT-SERVICE(5)](https://davmac.org/projects/dinit/man-pages-html/dinit-service.5.html) for all available options

dinit options documented with a : (colon) suffix should be nix lists. All options are mangled to strings. Lists are extracted into multiple rows.

command and stop-command does call lib.getExe if they get receive a derivation.

## How to test
Clone & cd repo, run. Which will launch nginx on port 8080 echoing Hello World.
```
nix run --file . config.out.dinitLauncher -- --user
```
