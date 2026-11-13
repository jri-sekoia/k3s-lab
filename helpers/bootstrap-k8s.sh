set -euo pipefail
umask 077

usage() {
  echo "Usage: nix run .#bootstrap-k8s -- {flannel|cilium|calico|render CNI|status|help}"
}

select_chart() {
  local component=$1
  case "$component" in
    flannel)
      chart=flannel
      repository=https://flannel-io.github.io/flannel
      namespace=kube-flannel
      ;;
    cilium)
      chart=cilium
      repository=https://helm.cilium.io
      namespace=kube-system
      ;;
    calico)
      chart=tigera-operator
      repository=https://docs.tigera.io/calico/charts
      namespace=tigera-operator
      ;;
    calico-crds)
      chart=crd.projectcalico.org.v1
      repository=https://docs.tigera.io/calico/charts
      namespace=tigera-operator
      component=calico
      ;;
    coredns)
      chart=coredns
      repository=https://coredns.github.io/helm
      namespace=kube-system
      ;;
    traefik)
      chart=traefik
      repository=https://traefik.github.io/charts
      namespace=traefik
      ;;
  esac
  chart_version=$(jq -er --arg component "$component" '.[$component]' "$LAB_CHART_VERSIONS")
}

install_chart() {
  local component=$1
  select_chart "$component"
  helm upgrade --install "$component" "$chart" --repo "$repository" \
    --version "$chart_version" --namespace "$namespace" --create-namespace \
    --values "$LAB_VALUES/${component%-crds}.yaml" --wait --timeout 10m
}

command=${1:-help}
case "$command" in
  help|--help|-h) usage; exit 0 ;;
  render)
    if [[ $# != 2 || ! "$2" =~ ^(flannel|cilium|calico)$ ]]; then
      usage >&2
      exit 1
    fi
    components=("$2" coredns traefik)
    if [[ "$2" == calico ]]; then
      components=(calico-crds "${components[@]}")
    fi
    for component in "${components[@]}"; do
      select_chart "$component"
      helm template "$component" "$chart" --repo "$repository" \
        --version "$chart_version" --namespace "$namespace" \
        --values "$LAB_VALUES/${component%-crds}.yaml" --kube-version 1.35.0 --include-crds
    done
    exit 0
    ;;
  flannel|cilium|calico|status)
    if [[ $# != 1 ]]; then
      usage >&2
      exit 1
    fi
    ;;
  *) usage >&2; exit 1 ;;
esac

state_dir="$PWD/.lab"
export KUBECONFIG="$PWD/k3s.yaml"
if [[ ! -f "$KUBECONFIG" || ! -f "$state_dir/inventory.json" ]]; then
  echo "Start the lab and export its kubeconfig with 'nix run . -- up' first." >&2
  exit 1
fi

exec 9>"$state_dir/lock"
if ! flock -n 9; then
  echo "Another lab command is running." >&2
  exit 1
fi

if [[ $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') != https://127.0.0.1:6443 ]]; then
  echo "Refusing to bootstrap outside the local lab API." >&2
  exit 1
fi

if [[ "$command" == status ]]; then
  helm list --all-namespaces
  kubectl get nodes
  kubectl get pods --all-namespaces
  exit 0
fi

if [[ "$LAB_EMBEDDED_FEATURES" == true ]]; then
  echo "Disable withEmbeddedFeatures and restart the lab before using Helm bootstrap." >&2
  exit 1
fi
if ! cmp -s "$LAB_INVENTORY" "$state_dir/inventory.json"; then
  echo "Restart the lab with 'nix run . -- down' then 'nix run . -- up' to apply its current configuration." >&2
  exit 1
fi

existing_cnis=$(helm list --all-namespaces --all --output json | jq -r '
  .[] | select(.name == "flannel" or .name == "cilium" or .name == "calico" or .name == "calico-crds")
  | if .name == "calico-crds" then "calico" else .name end')
while read -r existing_cni; do
  if [[ -n "$existing_cni" && "$existing_cni" != "$command" ]]; then
    echo "CNI $existing_cni is already installed. Use a fresh lab to test $command; live CNI switching is not supported." >&2
    exit 1
  fi
done <<<"$existing_cnis"

if [[ "$command" == flannel ]]; then
  kubectl create namespace kube-flannel --dry-run=client --output yaml | kubectl apply -f -
  kubectl label namespace kube-flannel pod-security.kubernetes.io/enforce=privileged --overwrite
fi

if [[ "$command" == calico ]]; then
  install_chart calico-crds
fi
install_chart "$command"
kubectl wait --for=condition=Ready nodes --all --timeout=10m
install_chart coredns
install_chart traefik
kubectl get nodes
helm list --all-namespaces
echo "Ingress: http://127.0.0.1:8080 and https://127.0.0.1:8443"