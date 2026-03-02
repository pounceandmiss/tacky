#!/usr/bin/env bash
# _lib.sh — shared library for XMPP server bootstrap scripts.
# Source this file; do not execute it directly.

# ─── Constants ───────────────────────────────────────────────────────────────

DOMAIN="example.local"
PORT_HOST=5222

USERS=(
  "test:testpass"
  "romeo:romeopass"
  "juliet:julietpass"
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

# Find and remove any container bound to PORT_HOST.
lib_ensure_port_free() {
  local container_name="$1"
  local cid
  cid=$(docker ps --filter "publish=${PORT_HOST}" --format '{{.ID}}' | head -n1 || true)
  if [ -n "$cid" ]; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}

# Pre-start cleanup: free port, remove temp dir, clean /etc/hosts.
lib_cleanup_stale() {
  local test_dir="$1"
  local container_name="$2"
  lib_ensure_port_free "$container_name"
  rm -rf "$test_dir" >/dev/null 2>&1 || true
  if grep -q -F "$DOMAIN" /etc/hosts 2>/dev/null; then
    sudo -- sh -c "sed -i '/[[:space:]]$DOMAIN\$/d' /etc/hosts" || true
  fi
}

# Teardown: stop container, clean /etc/hosts, remove temp dir.
lib_cleanup() {
  local container_name="$1"
  local test_dir="$2"
  local display_name="$3"
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  if grep -q -F "$DOMAIN" /etc/hosts 2>/dev/null; then
    sudo -- sh -c "sed -i '/[[:space:]]$DOMAIN\$/d' /etc/hosts" || true
  fi
  rm -rf "$test_dir"
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

# Wait for the server to become ready.
# $1 = display name, $2 = max wait seconds, $3 = interval seconds,
# $4 = check function name (called with no args, must return 0 when ready).
lib_wait_for_ready() {
  local display_name="$1"
  local max_wait="$2"
  local interval="$3"
  local check_fn="$4"
  local elapsed=0

  until "$check_fn"; do
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
  echo ">>> ${display_name} ready (${DOMAIN}:${PORT_HOST}, SPOOF_SSL_CERT=${SPOOF_SSL_CERT})"
  echo ""
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
