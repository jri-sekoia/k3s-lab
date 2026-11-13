{
  managerCount = 1;
  workerCount = 2;
  managerCpus = 1;
  managerMemory = 2048;
  workerCpus = 2;
  workerMemory = 4096;
  diskSize = 20480;
  withEmbeddedFeatures = false;
  extraServerFlags = [ ];
  chartVersions = {
    flannel = "v0.28.9";
    cilium = "1.20.2";
    calico = "v3.32.2";
    coredns = "1.48.1";
    traefik = "41.6.1";
  };
}