#!/usr/bin/env bash
# _lib.sh — shared library for XMPP server bootstrap scripts.
# Source this file; do not execute it directly.

# ─── Constants ───────────────────────────────────────────────────────────────

DOMAIN="example.local"

USERS=(
  "test:testpass"
  "romeo:romeopass"
  "juliet:julietpass"
  "omemoa:omemoapass"
  "omemob:omemobpass"
  "search1a:search1apass"
  "search1b:search1bpass"
  "search2a:search2apass"
  "search2b:search2bpass"
  "search3a:search3apass"
  "search3b:search3bpass"
  "search4a:search4apass"
  "search4b:search4bpass"
  "search5a:search5apass"
  "search5b:search5bpass"
  "search6a:search6apass"
  "search6b:search6bpass"
)

# ─── Functions ───────────────────────────────────────────────────────────────

# A TCP port nothing on this host is using, below the ephemeral range so an
# outgoing connection can't be holding it.
lib_pick_port() {
  local port
  while :; do
    port=$((20000 + RANDOM % 12000))
    if [ -z "$(ss -Htan "sport = :${port}")" ]; then
      echo "$port"
      return
    fi
  done
}

# Set each named variable to a different free port (`lib_pick_ports A B`),
# so concurrent runs and servers already on the default ports don't collide.
lib_pick_ports() {
  local name port taken=" "
  for name in "$@"; do
    port=$(lib_pick_port)
    while [[ $taken == *" $port "* ]]; do port=$(lib_pick_port); done
    taken+="$port "
    printf -v "$name" '%s' "$port"
  done
}

# Remove this run's containers and temp dir, before starting and on exit.
# The /etc/hosts entry stays: a concurrent run may still be using it.
# $1 = temp dir, then the container names.
lib_cleanup() {
  local test_dir="$1"
  shift
  local c
  for c in "$@"; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  rm -rf "$test_dir" >/dev/null 2>&1 || true
}

# Whether the output of a command contains $1. Reads the output whole:
# under pipefail, `cmd | grep -q` can fail with SIGPIPE.
# $1 = text to look for, then the command.
lib_output_has() {
  local needle="$1" out
  shift
  out=$(timeout 20 "$@" 2>/dev/null) || return 1
  [[ $out == *"$needle"* ]]
}

# Generate a self-signed cert with SAN for DOMAIN.
# Sets SPOOF_SSL_CERT in the environment.
lib_generate_certs() {
  local test_dir="$1"
  mkdir -p "${test_dir}/certs" "${test_dir}/conf"

  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},IP:127.0.0.1" \
    -keyout "${test_dir}/certs/${DOMAIN}.key" \
    -out "${test_dir}/certs/${DOMAIN}.crt" >/dev/null 2>&1

  chmod 644 "${test_dir}/certs/${DOMAIN}.key" "${test_dir}/certs/${DOMAIN}.crt"
  export SPOOF_SSL_CERT="${test_dir}/certs/${DOMAIN}.crt"
}

# Pull the Docker image.
lib_pull_image() {
  local image="$1"
  echo ">>> Pulling image: ${image}"
  docker pull --quiet "$image"
}

# Wait until a command succeeds, or exit.
# $1 = what is waited for, $2 = max wait seconds, $3 = interval seconds,
# then the command.
lib_wait_for_ready() {
  local display_name="$1"
  local max_wait="$2"
  local interval="$3"
  shift 3
  local elapsed=0

  until "$@"; do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "ERROR: ${display_name} did not start within ${max_wait}s."
      exit 1
    fi
  done
}

# Add example.local to /etc/hosts if missing.
lib_add_hosts_entry() {
  if ! grep -q -F "$DOMAIN" /etc/hosts; then
    sudo -- sh -c "echo '127.0.0.1 $DOMAIN' >> /etc/hosts"
  fi
}

# Create test user accounts.
# $1 = container name, $2 = register function name.
# The register function is called as: $register_fn $username $domain $password
lib_create_users() {
  local container_name="$1"
  local register_fn="$2"

  for entry in "${USERS[@]}"; do
    local username="${entry%%:*}"
    local password="${entry##*:}"

    "$register_fn" "$container_name" "$username" "$DOMAIN" "$password" || true
  done
}

# Print a single-line ready banner.
lib_banner() {
  local display_name="$1"
  echo ""
  echo ">>> ${display_name} ready (${DOMAIN}:${XMPP_PORT}, SPOOF_SSL_CERT=${SPOOF_SSL_CERT})"
  echo ""
}

# Once the server is up: hosts entry, users, banner, then the command.
# $1 = display name, $2 = container, $3 = register function, then the command.
lib_finish() {
  local display_name="$1" container_name="$2" register_fn="$3"
  shift 3
  lib_add_hosts_entry
  lib_create_users "$container_name" "$register_fn"
  lib_banner "$display_name"
  lib_run_command "$@"
}

# Run the user's command with proper exit-code handling.
lib_run_command() {
  if [ "$#" -eq 0 ]; then
    echo ">>> No command provided. Container will be torn down now."
    return 0
  fi

  set +e
  "$@"
  local exit_code=$?
  set -e
  exit ${exit_code}
}
