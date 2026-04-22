load_froth_env() {
  local app_root="${1:?app root is required}"
  local env_file="${FROTH_ENV_FILE:-$app_root/.env}"

  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
}

froth_node_name() {
  if [ -n "${FROTH_NODE_NAME:-}" ]; then
    printf '%s\n' "$FROTH_NODE_NAME"
    return
  fi

  local node_base="${FROTH_NODE_BASENAME:-froth}"
  local node_host="${FROTH_NODE_HOST:-$(hostname -s)}"
  printf '%s@%s\n' "$node_base" "$node_host"
}

set_froth_elixir_node_args() {
  local node_name="${1:-$(froth_node_name)}"
  local node_base="${node_name%%@*}"

  if [[ "$node_name" == *@*.* ]]; then
    FROTH_ELIXIR_NODE_FLAG="--name"
    FROTH_ELIXIR_NODE_VALUE="$node_name"
  else
    FROTH_ELIXIR_NODE_FLAG="--sname"
    FROTH_ELIXIR_NODE_VALUE="$node_base"
  fi
}

froth_rpc_client_name() {
  local target_node="${1:-$(froth_node_name)}"
  local client_base="${2:-rpc_$$}"
  local target_host="${target_node#*@}"

  if [[ "$target_node" == *@*.* ]]; then
    printf '%s@%s\n' "$client_base" "$target_host"
  else
    printf '%s\n' "$client_base"
  fi
}
