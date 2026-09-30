# A collection: the dinix configuration under test, plus what to ask the
# running system. dev.nix turns this into an image, a guest and a test.
#
# The control plane is unprivileged, so the interesting modes are the
# unprivileged ones: `user` runs the API server, etcd, the controllers, the
# scheduler and kwok all as nobody, with no root and no privilege anywhere.
# See services/kubernetes.nix and PORTING.md.
{ pkgs, config, lib, ... }:
let
  kubernetesService = lib.modules.importApply ../../services/kubernetes.nix {
    inherit (pkgs) kubernetes etcd kwok openssl bash coreutils;
  };

  main = config.system.services.kubernetes.kubernetes;

  kubectl = "${pkgs.kubernetes}/bin/kubectl";
  kubeconfig = "--kubeconfig=${main.dataDir}/kubeconfig";
in
{
  system.services.kubernetes = {
    imports = [ kubernetesService ];
  };

  collection = {
    writable = [ main.dataDir ];

    packages = [ pkgs.kubernetes ];

    checks = [
      {
        # etcd and the API server both have to be up for this to answer.
        name = "the API server reports itself ready";
        command = "${kubectl} ${kubeconfig} get --raw=/readyz";
        expect = "ok";
      }
      {
        # The node going Ready needs kwok *and* the controller-manager, which
        # takes the not-ready taint off once the condition is set.
        name = "kwok's node reports itself Ready";
        command = "${kubectl} ${kubeconfig} get nodes";
        expect = "Ready";
      }
      {
        name = "a namespace is created";
        command = "${kubectl} ${kubeconfig} create namespace dinix";
        expect = "created";
      }
      {
        # Retried until the controller-manager has put the `default` service
        # account in the new namespace, which is the admission plugin's demand.
        name = "a pod is created";
        command = "${kubectl} ${kubeconfig} run fake --image=busybox --restart=Never -n dinix";
        expect = "created";
      }
      {
        # Pending means the scheduler never placed it; Running means the
        # scheduler bound it to kwok's node and kwok ran the pod lifecycle.
        name = "and the scheduler and kwok take it to Running";
        command = "${kubectl} ${kubeconfig} get pod fake -n dinix -o jsonpath={.status.phase}";
        expect = "Running";
      }
    ];
  };
}
