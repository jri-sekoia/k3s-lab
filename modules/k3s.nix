{ config, lib, pkgs, ... }:

let
  cfg = config.lab.k3s;
  isServer = cfg.role == "server";

  serverFlags = [
    "--node-external-ip=${cfg.nodeIp}"
    "--tls-san=${cfg.serverIp}"
    "--tls-san=127.0.0.1"
    "--node-taint=node-role.kubernetes.io/control-plane:NoSchedule"
  ];

  externalComponentFlags = [
    "--flannel-backend=none"
    "--disable-network-policy"
    "--disable=traefik"
    "--disable=coredns"
    "--disable=local-storage"
    "--disable=metrics-server"
  ];

  flags = [ "--node-ip=${cfg.nodeIp}" ]
    ++ lib.optionals isServer serverFlags
    ++ lib.optionals (isServer && !cfg.withEmbeddedFeatures) externalComponentFlags
    ++ lib.optionals isServer cfg.extraServerFlags;
in
{
  options.lab.k3s = {
    role = lib.mkOption {
      type = lib.types.enum [ "server" "agent" ];
      default = "server";
    };

    nodeIp = lib.mkOption {
      type = lib.types.str;
      description = "This node's private-network IP (k3s --node-ip).";
    };

    serverIp = lib.mkOption {
      type = lib.types.str;
      description = "Control-plane private IP that agents join and the API cert is valid for.";
    };

    clusterInit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set on the first control-plane node only.";
    };

    token = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shared cluster join token.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime file containing the cluster join token.";
    };

    withEmbeddedFeatures = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable bundled networking, DNS, ingress, storage, and metrics components.";
    };

    extraServerFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional k3s server flags.";
    };
  };

  config = {
    services.k3s = {
      enable = true;
      inherit (cfg) role token tokenFile clusterInit;
      serverAddr = lib.mkIf (!cfg.clusterInit) "https://${cfg.serverIp}:6443";
      extraFlags = lib.concatStringsSep " " flags;
      containerdConfigTemplate = lib.mkIf (!cfg.withEmbeddedFeatures) ''
        {{ template "base" . }}
        [plugins."io.containerd.grpc.v1.cri".cni]
          bin_dir = "/var/lib/rancher/k3s/data/cni"
          conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"
      '';
    };

    boot.kernelModules = [ "br_netfilter" "overlay" ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
    };

    networking.firewall.allowedTCPPorts =
      [ 10250 4240 5473 80 443 30080 30443 ]
      ++ lib.optionals isServer [ 6443 2379 2380 ];
    networking.firewall.allowedUDPPorts = [ 8472 4789 ];
    networking.firewall.checkReversePath = "loose";
    networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" "cilium_host" "cilium_net" "lxc+" "cali+" "vxlan.calico" ];

    environment.systemPackages = with pkgs; [ k9s kubernetes-helm ];
    environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  };
}