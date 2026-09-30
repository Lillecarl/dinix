# The Kubernetes control plane, as a NixOS Modular Service.
#
# The control plane is unprivileged userland. etcd, kube-apiserver,
# kube-controller-manager and kube-scheduler each run as an ordinary process on
# an unprivileged port: no cgroup is written, no container is made, and nothing
# asks for a capability. That is what lets the `user` and `vm-user` modes of the
# test matrix run it as they run every other port. A node is different —
# kubelet needs cgroup v2 and mount privileges — so this module runs none.
#
# kwok (Kubernetes WithOut Kubelet) answers for the nodes instead: it marks a
# fake node Ready and drives the pods the scheduler binds, so etcd, the
# apiserver, the controllers and the scheduler all do real work with nothing
# privileged underneath.
#
# A Kubernetes component takes its certificates from files and its identity from
# a kubeconfig, and neither can live in a store path: the state directory is a
# template dinit expands, and a kubeconfig names paths under it. So
# kubernetes-init writes both once, with openssl. That makes this one of the
# rare ports whose closure carries a shell; see PORTING.md.
{ kubernetes, etcd, kwok, openssl, bash, coreutils }:

{
  config,
  options,
  name,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.kubernetes;

  bashExe = lib.getExe' bash "bash";
  opensslExe = lib.getExe' openssl "openssl";
  sleep = lib.getExe' coreutils "sleep";

  apiserver = lib.getExe' cfg.package "kube-apiserver";
  controllerManager = lib.getExe' cfg.package "kube-controller-manager";
  scheduler = lib.getExe' cfg.package "kube-scheduler";
  kubectl = lib.getExe' cfg.package "kubectl";

  # dinit expands the state directory in a command line, so these are the paths
  # a service description may name. The same paths written into a file are
  # written at runtime, by kubernetes-init.
  certs = "${cfg.dataDir}/certs";
  kubeconfig = "${cfg.dataDir}/kubeconfig";
  etcdServer = "http://${cfg.bind}:${toString cfg.etcd.clientPort}";

  # The node and pod lifecycle as the stage documents kwok ships. Each file is
  # one Stage, so each is one --config; kwok reads them all. Names taken from
  # the package's own tree rather than copied, so they follow the version.
  stageFiles = map (path: "${cfg.kwok.package.src}/kustomize/stage/${path}") [
    "node/fast/node-initialize.yaml"
    "node/heartbeat/node-heartbeat.yaml"
    "pod/fast/pod-ready.yaml"
    "pod/fast/pod-complete.yaml"
    "pod/fast/pod-delete.yaml"
  ];

  # Writes the cluster's keys and the kubeconfig the three clients share. The
  # keys are made once; the kubeconfig is rewritten every start, because it is
  # only ever read once and regenerating it costs nothing.
  initScript = ''
    set -eu
    dir="${cfg.dataDir}"
    certs="$dir/certs"
    if [ ! -e "$certs/ca.crt" ]; then
      ${opensslExe} genrsa -out "$certs/sa.key" 2048 2>/dev/null
      ${opensslExe} rsa -in "$certs/sa.key" -pubout -out "$certs/sa.pub" 2>/dev/null
      ${opensslExe} genrsa -out "$certs/ca.key" 2048 2>/dev/null
      ${opensslExe} req -x509 -new -nodes -key "$certs/ca.key" \
        -subj "/CN=dinix-ca" -days 3650 -out "$certs/ca.crt" 2>/dev/null
      ${opensslExe} genrsa -out "$certs/admin.key" 2048 2>/dev/null
      ${opensslExe} req -new -key "$certs/admin.key" \
        -subj "/CN=admin/O=system:masters" -out "$certs/admin.csr" 2>/dev/null
      ${opensslExe} x509 -req -in "$certs/admin.csr" -CA "$certs/ca.crt" \
        -CAkey "$certs/ca.key" -CAcreateserial -days 3650 \
        -out "$certs/admin.crt" 2>/dev/null
    fi
    printf '%s\n' \
      'apiVersion: v1' \
      'kind: Config' \
      'clusters:' \
      '- name: dinix' \
      '  cluster:' \
      "    server: https://${cfg.bind}:${toString cfg.apiserverPort}" \
      '    insecure-skip-tls-verify: true' \
      'users:' \
      '- name: admin' \
      '  user:' \
      "    client-certificate: $certs/admin.crt" \
      "    client-key: $certs/admin.key" \
      'contexts:' \
      '- name: dinix' \
      '  context:' \
      '    cluster: dinix' \
      '    user: admin' \
      'current-context: dinix' \
      > "$dir/kubeconfig"
  '';

  # The fake node kwok manages. Applied from a file, because the command line
  # is split on whitespace and a YAML document has newlines.
  nodeManifest = ''
    apiVersion: v1
    kind: Node
    metadata:
      name: ${cfg.kwok.nodeName}
      annotations:
        kwok.x-k8s.io/node: fake
  '';

  # Retried rather than run once: dinit starts a process service the moment it
  # spawns it, and the apiserver has not bound its port yet when its dependents
  # start. `apply` is idempotent, so a retry that finds the node already there
  # is a success.
  nodeScript = ''
    set -eu
    dir="${cfg.dataDir}"
    export KUBECONFIG="$dir/kubeconfig"
    until ${kubectl} apply -f "$1" >/dev/null 2>&1; do
      ${sleep} 1
    done
  '';
in
{
  _class = "service";

  options.kubernetes = {
    package = mkOption {
      type = types.package;
      default = kubernetes;
      defaultText = lib.literalMD "the kubernetes given to this module";
      description = "The Kubernetes release to run every component from.";
    };

    dataDir = mkOption {
      type = types.str;
      description = ''
        Everything this control plane keeps: etcd's data, the certificates and
        the kubeconfig.

        Defaults to the state directory the service manager names, where it
        names one. See {option}`redis.dataDir`.
      '';
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        The address every listener binds to.

        A container has its own network namespace, so `0.0.0.0` here is not the
        exposure it would be on a host. It is still not the default.
      '';
    };

    log = mkOption {
      type = types.enum [
        "console"
        "buffer"
        "file"
        "none"
      ];
      default = "buffer";
      description = ''
        Where the long-running components send their output.

        `buffer` by default, because a control plane is chatty and dinit keeps
        the console stream clear for its own messages, which is what a test
        reads. Read a buffer with `dinitctl catlog`. Set `console` to watch a
        run by hand.
      '';
    };

    apiserverPort = mkOption {
      type = types.port;
      default = 6443;
      description = "The port the API server serves on.";
    };

    schedulerPort = mkOption {
      type = types.port;
      default = 10259;
      description = "The port the scheduler's own secure server serves on.";
    };

    serviceClusterIPRange = mkOption {
      type = types.str;
      default = "10.0.0.0/24";
      description = ''
        The CIDR the API server allocates ClusterIPs from.

        Required in current Kubernetes: the old default is deprecated, and the
        API server warns about it until this is set.
      '';
    };

    serviceAccountIssuer = mkOption {
      type = types.str;
      default = "https://kubernetes.default.svc";
      description = "The `iss` claim of the service account tokens this cluster issues.";
    };

    etcd = {
      package = mkOption {
        type = types.package;
        default = etcd;
        defaultText = lib.literalMD "the etcd given to this module";
        description = "Which etcd to run.";
      };

      clientPort = mkOption {
        type = types.port;
        default = 2379;
        description = "The port the API server reaches etcd on.";
      };

      peerPort = mkOption {
        type = types.port;
        default = 2380;
        description = "The port etcd peers on. Unused with one node, but it still binds it.";
      };
    };

    kwok = {
      package = mkOption {
        type = types.package;
        default = kwok;
        defaultText = lib.literalMD "the kwok given to this module";
        description = "Which kwok answers for the nodes.";
      };

      nodeName = mkOption {
        type = types.str;
        default = "dinix-node";
        description = "The fake node kwok manages, so the scheduler has somewhere to place a pod.";
      };

      stages = mkOption {
        type = types.listOf types.path;
        description = ''
          The kwok stage documents, one `--config` each.

          Defaults to the node and pod lifecycle kwok ships, read from the
          package's own tree. Override to change the simulated lifecycle.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.kwok.stages != [ ];
          message = "kubernetes.kwok.stages is empty; kwok has no lifecycle to run.";
        }
      ];

      kubernetes.kwok.stages = lib.mkDefault stageFiles;

      configData = {
        "kubernetes-init.sh".text = initScript;
        "kubernetes-node.sh".text = nodeScript;
        "node.yaml".text = nodeManifest;
      };

      # The API server is the service. Everything else hangs off it.
      process.argv = [
        apiserver
        "--etcd-servers=${etcdServer}"
        "--bind-address=${cfg.bind}"
        # Without this the API server chooses its own address from the default
        # route, and a container has none: it exits 1 with "Unable to find
        # suitable network address". Loopback is the address everything here
        # already reaches it on.
        "--advertise-address=${cfg.bind}"
        "--secure-port=${toString cfg.apiserverPort}"
        "--cert-dir=${certs}"
        "--service-cluster-ip-range=${cfg.serviceClusterIPRange}"
        "--service-account-issuer=${cfg.serviceAccountIssuer}"
        "--service-account-key-file=${certs}/sa.pub"
        "--service-account-signing-key-file=${certs}/sa.key"
        "--client-ca-file=${certs}/ca.crt"
        "--authorization-mode=RBAC"
        # The endpoint reconciler refuses a loopback advertise address
        # ("may not be in the loopback range"), and a container that has no
        # default route has no other address to offer. Nothing here needs the
        # `kubernetes` Endpoints maintained, so it is turned off rather than
        # fought.
        "--endpoint-reconciler-type=none"
      ];
    }

    (lib.optionalAttrs (options ? dinit) {
      kubernetes.dataDir = lib.mkDefault config.dinit.stateDir;

      dinit.dirs = {
        ${cfg.dataDir}.mode = "0700";
        "${cfg.dataDir}/certs".mode = "0700";
        "${cfg.dataDir}/etcd".mode = "0700";
      };

      dinit.service = {
        # The keys have to exist and etcd has to be up before the API server
        # can serve. `depends-on` says both: it starts them first and stops the
        # API server if either stops.
        depends-on = [
          "${name}-init"
          "${name}-etcd"
        ];
        # The API server drains for longer than a shutdown should wait: it
        # keeps reaching for etcd, which dinit is already stopping beside it,
        # and retries until dinit's 10s default fires. Five seconds is well
        # inside the grace period a container runtime allows, and the process
        # is killed after that.
        stop-timeout = 5;
        dinix.critical = lib.mkDefault false;
        dinix.log = lib.mkDefault cfg.log;
      };

      services = {
        # The keys and the kubeconfig, once. A sub-service owns nothing by
        # itself, so the dependency is stated on whoever needs it.
        init = {
          process.argv = [
            bashExe
            config.configData."kubernetes-init.sh".path
          ];
          dinit.service = {
            type = "scripted";
            dinix.log = "console";
            dinix.critical = false;
          };
        };

        etcd = {
          process.argv = [
            (lib.getExe' cfg.etcd.package "etcd")
            "--data-dir=${cfg.dataDir}/etcd"
            "--listen-client-urls=${etcdServer}"
            "--advertise-client-urls=${etcdServer}"
            "--listen-peer-urls=http://${cfg.bind}:${toString cfg.etcd.peerPort}"
            "--initial-advertise-peer-urls=http://${cfg.bind}:${toString cfg.etcd.peerPort}"
            # Stated to match the advertise URL above. etcd's default is
            # `default=http://localhost:2380`, and it refuses to start when
            # that and the advertise URL disagree.
            "--initial-cluster=default=http://${cfg.bind}:${toString cfg.etcd.peerPort}"
          ];
          dinit.service = {
            dinix.critical = false;
            dinix.log = cfg.log;
          };
        };

        controller-manager = {
          process.argv = [
            controllerManager
            "--kubeconfig=${kubeconfig}"
            "--bind-address=${cfg.bind}"
            "--secure-port=0"
            "--service-cluster-ip-range=${cfg.serviceClusterIPRange}"
            "--service-account-private-key-file=${certs}/sa.key"
            "--root-ca-file=${certs}/ca.crt"
          ];
          dinit.service = {
            depends-on = [ name ];
            dinix.critical = false;
            dinix.log = cfg.log;
          };
        };

        scheduler = {
          process.argv = [
            scheduler
            "--kubeconfig=${kubeconfig}"
            "--bind-address=${cfg.bind}"
            "--secure-port=${toString cfg.schedulerPort}"
          ];
          dinit.service = {
            depends-on = [ name ];
            dinix.critical = false;
            dinix.log = cfg.log;
          };
        };

        kwok = {
          process.argv = [
            (lib.getExe' cfg.kwok.package "kwok")
            "--kubeconfig=${kubeconfig}"
            "--manage-all-nodes"
          ]
          ++ map (stage: "--config=${stage}") cfg.kwok.stages;
          dinit.service = {
            depends-on = [ name ];
            dinix.critical = false;
            dinix.log = cfg.log;
          };
        };

        node = {
          process.argv = [
            bashExe
            config.configData."kubernetes-node.sh".path
            config.configData."node.yaml".path
          ];
          dinit.service = {
            depends-on = [ name ];
            type = "scripted";
            dinix.log = "console";
            dinix.critical = false;
          };
        };
      };
    })
  ];

  meta.maintainers = [ ];
}
