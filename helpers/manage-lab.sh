set -euo pipefail
umask 077

state_dir="$PWD/.lab"
nodes_file="$state_dir/inventory.json"
proxy_dir="$state_dir/proxy"
export LAB_HTTP_PORT=${LAB_HTTP_PORT:-8080}
export LAB_HTTPS_PORT=${LAB_HTTPS_PORT:-8443}

mkdir -p "$state_dir"
exec 9>"$state_dir/lock"
if ! flock -n 9; then
  echo "Another lab command is running." >&2
  exit 1
fi

if [[ -d "$state_dir/api-proxy" && ! -d "$proxy_dir" ]]; then
  mv "$state_dir/api-proxy" "$proxy_dir"
fi

is_running() {
  local process_dir=$1
  [[ -f "$process_dir/pid" ]] && kill -0 "$(cat "$process_dir/pid")" 2>/dev/null
}

ssh_node() {
  local node_name=$1 ssh_port
  shift
  ssh_port=$(jq -er --arg name "$node_name" '.[] | select(.name == $name) | .sshPort' "$nodes_file")

  ssh -F /dev/null -i "$state_dir/id_ed25519" -p "$ssh_port" \
    -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$state_dir/known_hosts" root@127.0.0.1 "$@"
}

export_kubeconfig() {
  local manager_name temporary_file
  temporary_file=$(mktemp "$state_dir/kubeconfig.XXXXXX")

  while read -r manager_name; do
    if ssh_node "$manager_name" cat /etc/rancher/k3s/k3s.yaml 2>/dev/null \
      | yq '.clusters[].cluster.server = "https://127.0.0.1:6443"' >"$temporary_file" \
      && [[ -s "$temporary_file" ]]; then
      mv "$temporary_file" "$PWD/k3s.yaml"
      return
    fi
  done < <(jq -r '.[] | select(.role == "server") | .name' "$nodes_file")

  rm -f "$temporary_file"
  echo "No manager has a kubeconfig yet." >&2
  return 1
}

start_node() {
  local node_name=$1 runner_path=$2
  local node_dir="$state_dir/$node_name"

  if is_running "$node_dir"; then
    return
  fi

  mkdir -p "$node_dir"
  rm -f "$node_dir/control.sock"
  (
    cd "$node_dir"
    exec nohup "$runner_path/bin/microvm-run" </dev/null >console.log 2>&1 9>&-
  ) &
  echo "$!" >"$node_dir/pid"
  printf 'Starting %s\n' "$node_name"
}

stop_node() {
  local node_name=$1 process_id attempt
  local node_dir="$state_dir/$node_name"

  if is_running "$node_dir"; then
    process_id=$(cat "$node_dir/pid")
    if [[ -S "$node_dir/control.sock" ]]; then
      printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' \
        | socat -T 2 - UNIX-CONNECT:"$node_dir/control.sock",shut-none >/dev/null 2>&1 || true
    fi

    for ((attempt=0; attempt<120; attempt++)); do
      if ! kill -0 "$process_id" 2>/dev/null; then
        break
      fi
      sleep 1
    done

    if kill -0 "$process_id" 2>/dev/null; then
      echo "$node_name did not shut down; leaving it running. Inspect $node_dir/console.log." >&2
      return 1
    fi
    printf 'Stopped %s\n' "$node_name"
  fi

  rm -f "$node_dir/pid" "$node_dir/control.sock"
}

prepare_lab() {
  local node_dir launcher_path

  if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "Read/write access to /dev/kvm is required." >&2
    exit 1
  fi

  if [[ -f "$nodes_file" ]] && ! cmp -s "$LAB_INVENTORY" "$nodes_file"; then
    for node_dir in "$state_dir"/kube-*; do
      if is_running "$node_dir"; then
        echo "Stop the existing lab with 'nix run . -- down' before changing its configuration." >&2
        exit 1
      fi
    done
  fi

  launcher_path=$(dirname "$(dirname "$(readlink -f "$0")")")
  nix-store --add-root "$state_dir/booted" --indirect --realise "$launcher_path" >/dev/null
  install -m 600 "$LAB_INVENTORY" "$nodes_file"

  mkdir -p "$state_dir/shared"
  if [[ ! -f "$state_dir/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$state_dir/id_ed25519"
  fi
  cp "$state_dir/id_ed25519.pub" "$state_dir/shared/ssh.pub"

  if [[ ! -f "$state_dir/shared/token" ]]; then
    openssl rand -hex 32 >"$state_dir/shared/token"
  fi
}

start_proxy() {
  if is_running "$proxy_dir"; then
    return
  fi

  mkdir -p "$proxy_dir"
  haproxy -c -f "$LAB_PROXY"
  nohup haproxy -db -f "$LAB_PROXY" </dev/null >"$proxy_dir/console.log" 2>&1 9>&- &
  echo "$!" >"$proxy_dir/pid"
}

wait_for_api() {
  local attempt

  for ((attempt=0; attempt<120; attempt++)); do
    if ssh_node kube-manager1 k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
      return
    fi
    if ! is_running "$state_dir/kube-manager1" || ! is_running "$proxy_dir"; then
      break
    fi
    sleep 2
  done

  echo "API startup failed or timed out; inspect .lab/*/console.log. Guests are left running." >&2
  return 1
}

start_lab() {
  local node_name runner_path

  if (( LAB_HTTP_PORT < $(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)
    || LAB_HTTPS_PORT < $(cat /proc/sys/net/ipv4/ip_unprivileged_port_start) )); then
    echo "Ports $LAB_HTTP_PORT/$LAB_HTTPS_PORT require privileged binding on this host." >&2
    echo "Choose unprivileged ports with LAB_HTTP_PORT and LAB_HTTPS_PORT." >&2
    return 1
  fi

  prepare_lab
  while IFS=$'\t' read -r node_name runner_path; do
    start_node "$node_name" "$runner_path"
  done < <(jq -r '.[] | [.name, .runner] | @tsv' "$nodes_file")

  start_proxy
  wait_for_api
  export_kubeconfig
  ssh_node kube-manager1 k3s kubectl get nodes
  printf 'Kubeconfig: %s/k3s.yaml\n' "$PWD"
}

stop_lab() {
  local node_name shutdown_failed=false

  if [[ -f "$nodes_file" ]]; then
    while read -r node_name; do
      stop_node "$node_name" || shutdown_failed=true
    done < <(jq -r 'reverse | .[].name' "$nodes_file")

    if [[ "$shutdown_failed" == true ]]; then
      return 1
    fi
  fi

  if is_running "$proxy_dir"; then
    kill "$(cat "$proxy_dir/pid")"
  fi
  rm -f "$proxy_dir/pid"
}

show_status() {
  local node_name

  if [[ ! -f "$nodes_file" ]]; then
    echo "Lab has not been started."
    return
  fi

  while read -r node_name; do
    if is_running "$state_dir/$node_name"; then
      printf '%s running\n' "$node_name"
    else
      printf '%s stopped\n' "$node_name"
    fi
  done < <(jq -r '.[].name' "$nodes_file")
}

case "${1:-help}" in
  up) start_lab ;;
  down) stop_lab ;;
  status) show_status ;;
  stop)
    if [[ $# != 2 ]]; then
      echo "Usage: nix run . -- stop NODE" >&2
      exit 1
    fi
    jq -e --arg name "$2" 'any(.[]; .name == $name)' "$nodes_file" >/dev/null
    stop_node "$2"
    ;;
  start)
    if [[ $# != 2 ]]; then
      echo "Usage: nix run . -- start NODE" >&2
      exit 1
    fi
    runner_path=$(jq -er --arg name "$2" '.[] | select(.name == $name) | .runner' "$nodes_file")
    start_node "$2" "$runner_path"
    ;;
  ssh)
    if [[ $# -lt 2 ]]; then
      echo "Usage: nix run . -- ssh NODE [COMMAND...]" >&2
      exit 1
    fi
    shift
    ssh_node "$@"
    ;;
  kubeconfig) export_kubeconfig ;;
  help|--help|-h)
    echo "Usage: nix run . -- {up|down|status|start NODE|stop NODE|ssh NODE [COMMAND...]|kubeconfig}"
    ;;
  *)
    echo "Unknown command: $1" >&2
    exit 1
    ;;
esac