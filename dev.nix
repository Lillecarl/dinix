# Development entry point. Nothing in default.nix imports this, so neither
# nix2container nor a test harness reaches a dinix consumer's closure.
#
# It answers two questions with a measurement rather than a guess.
#
# How many layers, and how many bytes, does an image cost?
#
#   nix run --file ./dev.nix report
#
# And does a dinix container work when something other than this machine runs
# it? user-mode-nixos boots a guest, podman runs the image in it, and the test
# asserts against the running container.
#
#   nix build --file ./dev.nix containerTest rootlessTest   # in a build sandbox
#   nix run   --file ./dev.nix containerTest.run            # outside it
#
# Two of them, because sshd separates privileges or not according to its own
# uid, and dinix renders a different configuration for each.
#
{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; },
  modules ? [ ./demo.nix ],
  # Same revision nixidae pins, so the two agree.
  nix2container-src ? builtins.fetchGit {
    url = "https://github.com/nlewo/nix2container.git";
    rev = "b6ac40ef110c12ab1651fce5ea563f7837236439";
    allRefs = true;
  },
  # lib.nix is the door for a caller with its own guests and its own script,
  # and takes a package set. Going through default.nix instead would pull in
  # the nixidae umbrella, which resolves every source of that repository and
  # has nothing to say about this one.
  user-mode-nixos-src ? builtins.fetchGit {
    url = "https://github.com/Lillecarl/user-mode-nixos.git";
    rev = "136e93112f40e20c07aa6a334158543b63112971";
    allRefs = true;
  },
}:

let
  inherit (pkgs) lib;

  inherit (import nix2container-src { inherit pkgs; }) nix2container;

  # maxLayers turns on nix2container's automatic layering, which gives the
  # biggest store paths a layer each. That is the setting where a store path
  # costs a layer, and so the setting consolidateConfig is about. The default
  # of 1 puts the whole closure in a single layer and would measure nothing.
  imageFor =
    consolidate:
    let
      dinix = import ./. {
        inherit pkgs;
        modules = modules ++ [ { consolidateConfig = consolidate; } ];
      };
    in
    nix2container.buildImage {
      name = "dinix-${if consolidate then "consolidated" else "split"}";
      config.entrypoint = [ (lib.getExe dinix.config.containerWrapper) ];
      maxLayers = 100;
    };

  consolidated = imageFor true;
  split = imageFor false;

  uml = import (user-mode-nixos-src + "/lib.nix") { inherit pkgs; };

  # The guest every test runs in. It is a NixOS configuration and nothing more
  # than podman plus an ssh client.
  testGuest = {
    virtualisation.podman.enable = true;
    environment.systemPackages = [ pkgs.openssh ];
    boot.uml = {
      memory = "2048M";
      # The image unpacks into the guest's own filesystem rather than being
      # read out of the store, so the disk holds a copy of the closure. A
      # sparse file, so this costs nothing until it is used.
      diskSize = 8192;
    };
  };

  # Made at build time and not reproducible, which is right here: the test
  # wants a key nothing else has, and Nix caches the derivation anyway.
  clientKey =
    pkgs.runCommand "dinix-test-key"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir --parents $out
        ssh-keygen -t ed25519 -N "" -C dinix-test -f $out/id_ed25519
        cp $out/id_ed25519.pub $out/authorized_keys
      '';

  # The dinit control protocol client, with its own tests. A developer output:
  # no dinix wrapper or image refers to it.
  dinitClient = pkgs.callPackage ./dinit-client/package.nix { };

  # The Textual TUI, built on the client. Another developer output.
  tui = pkgs.callPackage ./tui/package.nix { inherit dinitClient; };

  # The option reference, rendered from the doc comments in options.nix.
  docs = import ./docs { inherit pkgs; modules = [ ./demo.nix ]; };

  # A runnable example. The file evaluates to a dinix configuration; this wraps
  # it in a shell script that starts dinit from its tuiWrapper on a fresh
  # runtime directory and opens the TUI on the socket. nix reload rebuilds the
  # same file and points the runtime at the result, so `n` after an edit adopts
  # it.
  exampleRunner =
    label: file:
    let
      example = import file { inherit pkgs; };
    in
    pkgs.writeShellApplication {
      name = "dinix-example-${label}";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        if [ -n "''${DINIX_RUNTIME_DIR:-}" ]; then
          runtime_dir="$DINIX_RUNTIME_DIR"
        else
          runtime_dir="$(mktemp -d)"
          created=1
        fi
        export DINIX_RUNTIME_DIR="$runtime_dir"
        # Writable state, outside the store and outside the checkout, so a redis
        # or a postgres in an example has somewhere to keep it. dinix-init makes
        # the directories under it before anything starts.
        export DINIX_STATE_DIR="''${DINIX_STATE_DIR:-$runtime_dir/state}"
        # The contract nix reload expects: build a configuration and print its
        # config directory. This rebuilds the example file itself.
        export DINIX_TUI_NIX_COMMAND="nix build --file ${toString file} config.configDir --no-link --print-out-paths"

        "${lib.getExe' example.config.tuiWrapper "dinit"}" &
        dinit_pid=$!
        cleanup() {
          kill "$dinit_pid" 2>/dev/null || true
          wait "$dinit_pid" 2>/dev/null || true
          [ -n "''${created:-}" ] && rm --recursive --force "$runtime_dir"
        }
        trap cleanup EXIT

        socket="$runtime_dir/control"
        for _ in $(seq 1 100); do
          [ -S "$socket" ] && break
          sleep 0.05
        done

        ${lib.getExe tui} --socket-path "$socket"
      '';
    };

  # Every example file, keyed the way the README names them. hello is a file;
  # a category is a directory of files and nests one level deeper.
  exampleFiles = {
    hello = ./examples/hello.nix;
    features = {
      dependencies = ./examples/features/dependencies.nix;
      restart = ./examples/features/restart.nix;
      logs = ./examples/features/logs.nix;
      ready = ./examples/features/ready.nix;
      critical = ./examples/features/critical.nix;
    };
    services = {
      redis = ./examples/services/redis.nix;
      postgres = ./examples/services/postgres.nix;
      nginx = ./examples/services/nginx.nix;
      memcached = ./examples/services/memcached.nix;
    };
    containers = {
      redis = ./examples/containers/redis.nix;
      nginx = ./examples/containers/nginx.nix;
    };
    api = {
      usage = ./examples/api/usage.nix;
      modular = ./examples/api/modular.nix;
    };
  };

  # label is the dotted path, so the script and its failures name the example.
  walkExamples =
    label: node:
    if builtins.isAttrs node then
      lib.mapAttrs (segment: child: walkExamples "${label}.${segment}" child) node
    else
      exampleRunner (lib.removePrefix "." label) node;

  examples = walkExamples "" exampleFiles;

  # Every example with a flat, dash-joined name, for the checks below.
  flatExamples =
    let
      go =
        prefix: node:
        if builtins.isAttrs node then
          lib.concatLists (
            lib.mapAttrsToList (
              segment: child: go (if prefix == "" then segment else "${prefix}-${segment}") child
            ) node
          )
        else
          [
            {
              name = prefix;
              file = node;
            }
          ];
    in
    go "" exampleFiles;

  # The README quick start, kept under its old name.
  example = examples.hello;

  # An image for a container example. The entrypoint is dinix's own container
  # wrapper, so the image needs no shell and no writable root.
  containerFor =
    label: file:
    let
      example = import file { inherit pkgs; };
    in
    nix2container.buildImage {
      name = "dinix-example-${label}";
      tag = "latest";
      config.entrypoint = [ (lib.getExe example.config.containerWrapper) ];
      maxLayers = 100;
    };

  containers = lib.mapAttrs containerFor {
    redis = ./examples/containers/redis.nix;
    nginx = ./examples/containers/nginx.nix;
  };

  # Two dinix instances for the client's integration check, identical but for
  # the line the hello service prints. They arrive in the check as environment
  # variables, so the test suite can repoint a symlink from A to B and prove
  # that reload re-reads the description from dinit's service directory list.
  clientInstanceA = import ./dinit-client/tests/instance.nix { inherit pkgs; };
  clientInstanceB = import ./dinit-client/tests/instance.nix {
    inherit pkgs;
    marker = "hello-from-swapped";
  };

  # Drives a real dinit through the client. The unit tests use a fake daemon;
  # this proves the wire format, the native struct sizes, the events and the
  # reload path against dinit itself. dinit runs from an unbaked package so the
  # check, not a wrapper, chooses the service directory.
  dinitClientIntegration = pkgs.runCommand "dinit-client-integration"
    {
      nativeBuildInputs = [
        (pkgs.python3.withPackages (ps: [
          ps.anyio
          ps.pytest
          dinitClient
        ]))
      ];
      DINIT_CLIENT_TEST_DINIT = lib.getExe' clientInstanceA.config.package "dinit";
      DINIT_CLIENT_TEST_INSTANCE_A = "${clientInstanceA.config.configDir}";
      DINIT_CLIENT_TEST_INSTANCE_B = "${clientInstanceB.config.configDir}";
    }
    ''
      export HOME="$TMPDIR"
      python -m pytest ${./dinit-client/tests}/test_real_dinit.py \
        -o anyio_mode=auto -p no:cacheprovider
      touch $out
    '';

  # Drives the whole stack against a real dinit: the Textual pilot, the app,
  # the control client. Same two instances as the client's check, differing in
  # the line hello prints; a nix reload points the runtime pointer at B and a
  # restart proves the app adopted it.
  tuiIntegration = pkgs.runCommand "tui-integration"
    {
      nativeBuildInputs = [
        (pkgs.python3.withPackages (ps: [
          ps.anyio
          ps.pytest
          ps.textual
          dinitClient
        ]))
      ];
      DINIX_TUI_TEST_DINIT = lib.getExe' clientInstanceA.config.package "dinit";
      DINIX_TUI_TEST_INSTANCE_A = "${clientInstanceA.config.configDir}";
      DINIX_TUI_TEST_INSTANCE_B = "${clientInstanceB.config.configDir}";
      # withPackages drops a buildPythonApplication from PYTHONPATH (its
      # pythonModule is false), so the app under test is named directly.
      PYTHONPATH = lib.makeSearchPath pkgs.python3.sitePackages [ tui ];
    }
    ''
      export HOME="$TMPDIR"
      python -m pytest ${./tui/tests}/test_integration.py \
        -o anyio_mode=auto -p no:cacheprovider
      touch $out
    '';

  # The Python tools below act on the working tree, not a store copy, so each
  # finds the repository root and works from any subdirectory. `jj root` first
  # because this is a jj repo; git and pwd cover the other cases.
  repoRoot = ''
    root=$(jj root 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || pwd)
    cd "$root"
  '';

  ruffInputs = [
    pkgs.python3Packages.ruff
    pkgs.jujutsu
    pkgs.git
  ];

  # Format the Python, or check that it is already formatted.
  format = pkgs.writeShellApplication {
    name = "dinix-format";
    runtimeInputs = ruffInputs;
    text = ''
      ${repoRoot}
      ruff check --fix dinit-client tui
      ruff format dinit-client tui
    '';
  };

  lint = pkgs.writeShellApplication {
    name = "dinix-lint";
    runtimeInputs = ruffInputs;
    text = ''
      ${repoRoot}
      ruff check dinit-client tui
      ruff format --check dinit-client tui
    '';
  };

  # Run the Python tests against the working tree, without a Nix build.
  test = pkgs.writeShellApplication {
    name = "dinix-test";
    runtimeInputs = [
      (pkgs.python3.withPackages (ps: [
        ps.anyio
        ps.pytest
        ps.textual
      ]))
      pkgs.jujutsu
      pkgs.git
      pkgs.coreutils
    ];
    text = ''
      ${repoRoot}
      export PYTHONPATH="$root/dinit-client/src:$root/tui/src"
      # A private basetemp. Otherwise pytest prunes the shared
      # /tmp/pytest-of-$USER, and every read-only store file in another
      # project's leftovers becomes its own warning.
      basetemp="$(mktemp -d)"
      trap 'rm --recursive --force "$basetemp"' EXIT
      python -m pytest --basetemp="$basetemp" dinit-client/tests tui/tests "$@"
    '';
  };

  /**
    One container test: an image from `extraModules`, and the guest that runs
    it.

    Two of these, because sshd decides by its own uid whether it separates
    privileges, and dinix renders a different configuration for each. One
    script drives both; `settings` carries what differs.
  */
  containerTestFor =
    {
      name,
      extraModules ? [ ],
      # The uid the container runs as, and the account sshd will serve.
      uid ? 0,
      podmanUser ? "",
    }:
    let
      dinix = import ./. {
        inherit pkgs;
        modules = [
          ./tests/container.nix
          { _module.args.clientKey = clientKey; }
        ]
        ++ extraModules;
      };

      image = nix2container.buildImage {
        inherit name;
        tag = "test";
        # sshd runs the login shell named in passwd, and then looks for the
        # command on a PATH of /usr/bin:/bin:/usr/sbin:/sbin, which it compiles
        # in. So an ssh container needs /bin/sh and a few tools whatever else it
        # carries; dinix's own services need none of it.
        copyToRoot = pkgs.buildEnv {
          name = "${name}-root";
          paths = [ pkgs.busybox ];
          pathsToLink = [ "/bin" ];
        };
        config.entrypoint = [ (lib.getExe dinix.config.containerWrapper) ];
        maxLayers = 100;
      };

      loginUser =
        lib.findFirst (account: account.uid == uid)
          (throw "no account in the test configuration has uid ${toString uid}")
          (lib.attrValues dinix.config.users.users);
    in
    uml.mkTest {
      inherit name;
      script = ./tests/openssh.py;
      nodes.node = testGuest;
      settings = {
        inherit uid podmanUser;
        loginUser = loginUser.name;
        copyToPodman = lib.getExe image.copyToPodman;
        imageRef = "${image.imageName}:${image.imageTag}";
        clientKey = "${clientKey}";
        configDir = "${dinix.config.configDir}";
        dinitctl = "${dinix.config.containerWrapper}/bin/dinitctl";
        port = dinix.config.system.services.sshd.openssh.settings.Port;
        caBundle = dinix.config.caCertificates.file;
        # /run holds dinit's control socket and the generated host keys.
        # /var/empty is sshd's privilege separation directory, which a rootless
        # sshd never looks at. /data is the volume mustExist asks for, and the
        # test runs the container a second time without it.
        mustExist = "/data";
        tmpfs = [
          "/run"
          "/data"
        ]
        ++ lib.optional (uid == 0) "/var/empty";
      };
    };

  /**
    A test for a collection of services, driven by what the collection
    declares rather than by a script of its own.

    This is what a service port uses. `tests/collections/<name>.nix` is an
    ordinary dinix configuration plus a `collection` attribute saying which
    writable paths the services need and what to ask the running system.
    No Python. See PORTING.md.

    Four test modes: the two axes an environment is made of, crossed.
    Whether there is a container decides which wrapper runs; whether dinit
    is root decides whether a service may drop privilege with run-as, and
    that is the only one the configuration has to know in advance.

    - `root`: a container, dinit as root.
    - `user`: the same container run as nobody.
    - `vm-root`: no container, dinit as root on the guest — the systemd shape.
    - `vm-user`: no container, dinit --user as an ordinary account.
  */
  collectionTest =
    name: testMode:
    let
      # The two axes the four test modes are made of. Only one of them is a
      # configuration question: whether dinit will be root, and so whether a
      # service may use run-as. The other decides which wrapper the driver
      # runs and nothing in the service descriptions.
      isVm = lib.hasPrefix "vm-" testMode;
      isPrivileged = testMode == "root" || testMode == "vm-root";

      dinix = import ./. {
        inherit pkgs;
        modules = [
          ./tests/collection-options.nix
          (./tests/collections + "/${name}.nix")
          { privileged = isPrivileged; }
        ];
      };

      # Where this run puts state. Not /var/lib, so that a passing test means
      # DINIX_STATE_DIR really was substituted at startup rather than the
      # built-in default happening to work.
      testStateDir = "/tmp/dinix-state";

      # A collection names a data directory the way a service does, so its
      # checks and its writable paths carry the same unexpanded
      # ${DINIX_STATE_DIR:-/var/lib} that dinit expands at load. Nothing
      # expands it for a `podman exec`, which takes an argument list and no
      # shell, so it is resolved here — where both the template and the value
      # this run chose are known. The driver stays free of a second expander.
      resolve = lib.replaceStrings [ (import ./service-lib.nix).stateDir ] [ testStateDir ];
      resolveCheck = check: check // { command = resolve check.command; };

      image = nix2container.buildImage (
        {
          name = "dinix-collection-${name}";
          tag = "test";
          # No copyToRoot by default. A collection needs no shell: every check
          # names an absolute store path, and dinit execs its services
          # directly. A check client the service packages do not ship arrives
          # through collection.packages instead.
          config.entrypoint = [ (lib.getExe dinix.config.containerWrapper) ];
          maxLayers = 100;
        }
        // lib.optionalAttrs (dinix.config.collection.packages != [ ]) {
          copyToRoot = pkgs.buildEnv {
            name = "dinix-collection-${name}-clients";
            paths = dinix.config.collection.packages;
            pathsToLink = [ "/bin" ];
          };
        }
      );
    in
    uml.mkTest {
      name = "dinix-collection-${name}-${testMode}";
      script = ./tests/collection.py;
      nodes.node = testGuest;
      settings = {
        collection = name;
        mode = testMode;
        configDir = "${dinix.config.configDir}";
        inherit (dinix.config.collection) services;
        checks = map resolveCheck dinix.config.collection.checks;
        writable = map resolve dinix.config.collection.writable;
        # The driver exports this into dinit's environment; dinit substitutes
        # service descriptions with it and dinix-init expands init.spec the
        # same way.
        stateDir = testStateDir;
        # The vm-user mode runs dinit --user; every other mode runs the
        # container entrypoint, on the guest directly where there is no
        # container. Only the wrapper a mode runs is referenced, so no
        # mode builds the other one's.
        dinit = "${
          if testMode == "vm-user" then dinix.config.userWrapper else dinix.config.containerWrapper
        }/bin/dinit";
        dinitctl = "${
          if testMode == "vm-user" then dinix.config.userWrapper else dinix.config.containerWrapper
        }/bin/dinitctl";
      }
      // lib.optionalAttrs (!isVm) {
        copyToPodman = lib.getExe image.copyToPodman;
        imageRef = "${image.imageName}:${image.imageTag}";
        # Empty when the container runs as root, which is podman's default.
        podmanUser = if testMode == "user" then "65534:65534" else "";
      };
    };

  # Every file in tests/collections is a test in four modes. Adding a
  # service port means adding a file there, and nothing in this one.
  collectionModes = [
    "root"
    "user"
    "vm-root"
    "vm-user"
  ];
  collections = lib.mapAttrs' (
    file: _:
    let
      name = lib.removeSuffix ".nix" file;
    in
    lib.nameValuePair name (lib.genAttrs collectionModes (collectionTest name))
  ) (builtins.readDir ./tests/collections);

  containerTest = containerTestFor { name = "dinix-openssh"; };

  rootlessTest = containerTestFor {
    name = "dinix-openssh-rootless";
    extraModules = [ ./tests/rootless.nix ];
    uid = 1000;
    podmanUser = "1000:1000";
  };

  /**
    Everything a change has to pass, under one name.

    `nix build --file ./dev.nix checks` builds every collection in every mode
    and both container tests. A test output is an empty file whose existence
    means it ran and behaved, so this is a symlink farm of them.

    One name rather than a list in a workflow: a collection added under
    `tests/collections` joins this by existing, and CI needs no edit to run it.
  */
  checks = pkgs.linkFarm "dinix-checks" (
    [
      {
        name = "container";
        path = containerTest;
      }
      {
        name = "container-rootless";
        path = rootlessTest;
      }
      {
        name = "dinit-client";
        path = dinitClient;
      }
      {
        name = "docs";
        path = docs.optionsCommonMark;
      }
      {
        name = "docs-site";
        path = docs.site;
      }
      {
        name = "dinit-client-integration";
        path = dinitClientIntegration;
      }
      {
        name = "tui";
        path = tui;
      }
      {
        name = "tui-integration";
        path = tuiIntegration;
      }
    ]
    # Every example, evaluated, so a broken one fails CI rather than a user's
    # first run.
    ++ map (
      example: {
        name = "example-${example.name}";
        path = (import example.file { inherit pkgs; }).config.configDir;
      }
    ) flatExamples
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: modes:
        lib.mapAttrsToList (mode: test: {
          name = "${name}-${mode}";
          path = test;
        }) modes
      ) collections
    )
  );

  # buildImage's output is a JSON manifest naming every layer and the store
  # paths in it, so the count and the sizes come from the image itself rather
  # than from counting the closure by hand.
  report = pkgs.writeShellApplication {
    name = "dinix-image-report";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      summarise() {
        local name=$1 manifest=$2
        printf '%-14s %2d layers  %s\n' \
          "$name" \
          "$(jq '.layers | length' "$manifest")" \
          "$(numfmt --to=iec --suffix=B "$(jq '[.layers[].size] | add' "$manifest")")"
      }
      summarise consolidated ${consolidated}
      summarise split ${split}
      echo
      echo "layers in the consolidated image, largest first:"
      jq --raw-output '
        .layers
        | sort_by(-.size)
        | .[]
        | "  \(.size | tostring | .[0:9]) bytes  \(.paths[0].path // "?" | split("/") | last)"
      ' ${consolidated}
    '';
  };
in
{
  inherit
    checks
    consolidated
    split
    report
    nix2container
    uml
    clientKey
    containerTest
    rootlessTest
    collections
    dinitClient
    dinitClientIntegration
    docs
    example
    examples
    containers
    format
    lint
    test
    tui
    tuiIntegration
    ;
}
// collections
