{ lib, pkgs, lab, node, ... }:

let
  macSuffix = lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString node.number));
  uplinkMac = "02:00:00:00:01:${macSuffix}";
  clusterMac = "02:00:00:00:02:${macSuffix}";
  nodeIp = "10.10.0.${toString node.number}";
in
{
  networking.hostName = node.name;
  system.stateVersion = "26.05";
  systemd.shutdownRamfs.enable = false;
  nix.enable = false;

  microvm = {
    hypervisor = "qemu";
    vcpu = node.cpus;
    mem = node.memory;
    socket = "control.sock";

    shares = [
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "store";
        proto = "9p";
        readOnly = true;
      }
      {
        source = "../shared";
        mountPoint = "/run/lab";
        tag = "lab";
        proto = "9p";
        readOnly = true;
      }
    ];

    volumes = [
      {
        image = "var.img";
        mountPoint = "/var";
        size = lab.diskSize;
      }
    ];

    interfaces = [
      {
        type = "user";
        id = "uplink";
        mac = uplinkMac;
      }
    ];

    forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = node.sshPort;
        guest.port = 22;
      }
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = node.httpPort;
        guest.port = 30080;
      }
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = node.httpsPort;
        guest.port = 30443;
      }
    ] ++ lib.optional (node.role == "server") {
      from = "host";
      host.address = "127.0.0.1";
      host.port = node.apiPort;
      guest.port = 6443;
    };

    qemu = {
      machine = "q35";
      extraArgs = [
        "-netdev"
        "socket,id=cluster,mcast=230.0.0.1:20000,localaddr=127.0.0.1"
        "-device"
        "virtio-net-pci,netdev=cluster,mac=${clusterMac},romfile="
      ];
    };
  };

  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network = {
    enable = true;

    links."10-uplink" = {
      matchConfig.MACAddress = uplinkMac;
      linkConfig.Name = "uplink0";
    };
    links."10-cluster" = {
      matchConfig.MACAddress = clusterMac;
      linkConfig.Name = "cluster0";
    };

    networks."10-uplink" = {
      matchConfig.Name = "uplink0";
      address = [ "10.0.2.15/24" ];
      gateway = [ "10.0.2.2" ];
      dns = [ "10.0.2.3" ];
    };
    networks."10-cluster" = {
      matchConfig.Name = "cluster0";
      address = [ "${nodeIp}/24" ];
      linkConfig.RequiredForOnline = "routable";
    };
  };

  lab.k3s = {
    inherit (node) role clusterInit;
    inherit (lab) withEmbeddedFeatures extraServerFlags;
    inherit nodeIp;
    serverIp = "10.10.0.10";
    tokenFile = "/run/lab/token";
  };

  systemd.services.k3s = {
    requires = [ "run-lab.mount" ];
    after = [ "run-lab.mount" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/rancher/k3s" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/node 0700 root root -"
    "L+ /etc/rancher/node - - - - /var/lib/rancher/node"
  ];

  services.openssh = {
    enable = true;
    authorizedKeysFiles = [ "/run/lab-authorized-keys" ];
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
    hostKeys = [
      {
        path = "/var/lib/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  systemd.services.sshd = {
    requires = [ "run-lab.mount" ];
    after = [ "run-lab.mount" ];
    preStart = "${pkgs.coreutils}/bin/install -m 600 /run/lab/ssh.pub /run/lab-authorized-keys";
  };
}