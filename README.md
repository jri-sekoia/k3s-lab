# k3s Lab

A local, multi-node k3s cluster in NixOS microVMs using QEMU/KVM.
Each node has its own kernel, network interface, and persistent disk;
k3s runs only inside the guests.

Requires Linux, Nix with flakes enabled, and read/write access to `/dev/kvm`.
Run commands from the project root.

While the flake files are untracked in Git, replace `.` with `"path:$PWD"`
in Nix commands, for example `nix run "path:$PWD#bootstrap-k8s" -- cilium`.

## Commands

| Command | Purpose |
| --- | --- |
| `nix run . -- up` | Start the cluster and export its kubeconfig |
| `nix run . -- down` | Shut down the cluster, keeping its data |
| `nix run . -- status` | Show which guests are running |
| `nix run . -- stop kube-worker1` | Shut down one node |
| `nix run . -- start kube-worker1` | Start an existing node |
| `nix run . -- ssh kube-manager1` | Open a root SSH session |
| `nix run . -- ssh kube-manager1 k3s kubectl get nodes` | Run a guest command |
| `nix run . -- kubeconfig` | Refresh the local kubeconfig |
| `nix run . -- help` | Show available commands |

The API is available at `https://127.0.0.1:6443` using `k3s.yaml`:

```sh
nix shell nixpkgs#kubectl --command kubectl --kubeconfig ./k3s.yaml get nodes
```

Guest disks, keys, and logs live in `.lab/`. For startup diagnostics:

```sh
tail -n 100 .lab/kube-manager1/console.log
```

## Bootstrap

After starting the lab, choose one CNI. Each command installs or upgrades
that CNI, CoreDNS, and Traefik using Helm:

```sh
nix run .#bootstrap-k8s -- flannel
nix run .#bootstrap-k8s -- cilium
nix run .#bootstrap-k8s -- calico
```

Use only one CNI per lab; switching requires a fresh cluster. Keep
`withEmbeddedFeatures = false` when using Helm bootstrap.

| Command | Purpose |
| --- | --- |
| `nix run .#bootstrap-k8s -- status` | Show Helm releases, nodes, and pods |
| `nix run .#bootstrap-k8s -- render cilium` | Render manifests without installing |

The generic HAProxy provides localhost-only access:

- Kubernetes API: `https://127.0.0.1:6443`.
- Traefik HTTP: `http://127.0.0.1:8080`.
- Traefik HTTPS: `https://127.0.0.1:8443` (Traefik terminates TLS).
- HAProxy statistics: [http://127.0.0.1:8404/stats](http://127.0.0.1:8404/stats).

Ingress routes and certificates are configured in Kubernetes. Unmatched
requests return Traefik's 404 response; its default TLS certificate is self-signed.
Proxy logs are in `.lab/proxy/console.log`.