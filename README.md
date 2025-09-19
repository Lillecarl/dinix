# dinix

Create dinit configurations with the NixOS module system

## dinix -> dinit option mapping:
See [DINIT-SERVICE(5)](https://davmac.org/projects/dinit/man-pages-html/dinit-service.5.html) for all available options

* depends-on.d <-> depends-on-d
* depends-ms.d <-> depends-ms-d
* waits-for.d <-> waits-for-d
* @include <-> include
* @include-opt <-> include-opt

These mappings are made so you don't have to wrap attribute names in quotes.

## How to test
Clone & cd repo, run. Which will launch nginx on port 8080 echoing Hello World.
```
nix run --file . config.out.dinitLauncher -- --user
```
