{
  description = "Local multi-node k3s lab in NixOS microVMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    microvm.url = "github:microvm-nix/microvm.nix/81f70a2002254f75b572fc34c55e7df16e9bb176";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, microvm, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      lab = import ./settings.nix;

      totalCpus = lab.managerCount * lab.managerCpus + lab.workerCount * lab.workerCpus;
      totalMemory = lab.managerCount * lab.managerMemory + lab.workerCount * lab.workerMemory;
      validTopology = lab.managerCount >= 1 && lab.managerCount <= 3 && lab.workerCount >= 0;
      validResources = lab.managerCpus >= 1 && lab.workerCpus >= 1
        && lab.managerMemory >= 2048 && lab.workerMemory >= 2048
        && totalCpus <= 8 && totalMemory <= 16384;

      managers = lib.genList (index: {
        name = "kube-manager${toString (index + 1)}";
        role = "server";
        cpus = lab.managerCpus;
        memory = lab.managerMemory;
        number = index + 10;
        sshPort = 2201 + index;
        apiPort = 16443 + index;
        httpPort = 18080 + index;
        httpsPort = 18443 + index;
        clusterInit = index == 0;
      }) lab.managerCount;

      workers = lib.genList (index: {
        name = "kube-worker${toString (index + 1)}";
        role = "agent";
        cpus = lab.workerCpus;
        memory = lab.workerMemory;
        number = index + 21;
        sshPort = 2221 + index;
        apiPort = null;
        httpPort = 18090 + index;
        httpsPort = 18453 + index;
        clusterInit = false;
      }) lab.workerCount;

      nodes = managers ++ workers;

      makeGuest = node: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit lab node; };
        modules = [
          microvm.nixosModules.microvm
          ./modules/microvm.nix
          ./modules/k3s.nix
        ];
      };

      guests = lib.listToAttrs (map (node: {
        name = node.name;
        value = makeGuest node;
      }) nodes);

      runners = lib.mapAttrs (_: guest: guest.config.microvm.declaredRunner) guests;

      inventory = pkgs.writeText "lab-nodes.json" (builtins.toJSON (map (node: node // {
        runner = runners.${node.name};
      }) nodes));

      managerBackends = lib.concatMapStringsSep "\n  " (manager:
        "server ${manager.name} 127.0.0.1:${toString manager.apiPort} check check-ssl verify none"
      ) managers;

      ingressNodes = if workers != [ ] then workers else managers;
      ingressBackends = port: lib.concatMapStringsSep "\n  " (node:
        "server ${node.name} 127.0.0.1:${toString node.${port}} check"
      ) ingressNodes;

      proxyConfig = pkgs.writeText "lab-proxy.cfg" ''
        global
          maxconn 256
        defaults
          mode tcp
          timeout connect 5s
          timeout client 1h
          timeout server 1h
        frontend api
          bind 127.0.0.1:6443
          default_backend managers
        backend managers
          option tcp-check
          balance roundrobin
          ${managerBackends}
        frontend http
          bind "127.0.0.1:$LAB_HTTP_PORT"
          default_backend ingress_http
        backend ingress_http
          balance roundrobin
          ${ingressBackends "httpPort"}
        frontend https
          bind "127.0.0.1:$LAB_HTTPS_PORT"
          default_backend ingress_https
        backend ingress_https
          balance roundrobin
          ${ingressBackends "httpsPort"}
        listen stats
          bind 127.0.0.1:8404
          mode http
          stats enable
          stats uri /stats
          stats refresh 5s
          stats hide-version
      '';

      labManager = pkgs.writeShellApplication {
        name = "k3s-lab";
        runtimeInputs = with pkgs; [
          coreutils
          util-linux
          nix
          openssh
          openssl
          jq
          yq-go
          socat
          haproxy
        ];
        text = ''
          export LAB_INVENTORY=${inventory}
          export LAB_PROXY=${proxyConfig}
        '' + builtins.readFile ./helpers/manage-lab.sh;
      };

      bootstrapK8s = pkgs.writeShellApplication {
        name = "bootstrap-k8s";
        runtimeInputs = with pkgs; [ coreutils util-linux kubernetes-helm kubectl jq ];
        text = ''
          export LAB_CHART_VERSIONS=${pkgs.writeText "lab-chart-versions.json" (builtins.toJSON lab.chartVersions)}
          export LAB_VALUES=${./bootstrap}
          export LAB_INVENTORY=${inventory}
          export LAB_EMBEDDED_FEATURES=${lib.boolToString lab.withEmbeddedFeatures}
        '' + builtins.readFile ./helpers/bootstrap-k8s.sh;
      };
    in
    assert lib.assertMsg (validTopology && validResources)
      "Lab requires 1..3 managers, non-negative workers, and a maximum of 8 vCPU / 16 GiB.";
    {
      nixosConfigurations = guests;
      packages.${system} = runners // { default = labManager; bootstrap-k8s = bootstrapK8s; };
      apps.${system} = {
        default = {
          type = "app";
          program = "${labManager}/bin/k3s-lab";
        };
        bootstrap-k8s = {
          type = "app";
          program = "${bootstrapK8s}/bin/bootstrap-k8s";
        };
      };
    };
}