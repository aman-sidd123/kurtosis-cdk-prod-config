#!/usr/bin/env bash

set -euo pipefail

ENCLAVE_NAME="${1:-cdk}"
ENCLAVE_UUID="${2:-}"

LOG_COLLECTOR_VOLUME_PREFIX="kurtosis-logs-collector-vol--"
LOG_COLLECTOR_CONTAINER_PREFIX="kurtosis-logs-collector--"
NETWORK_PREFIX="kt-"

# Start services in the same high-level order Kurtosis CDK deploys them:
# L1 -> helper infra -> agglayer -> cdk-erigon chain -> bridge infra -> dashboards.
STARTUP_SERVICE_ORDER=(
  "el-1-geth-lighthouse"
  "cl-1-lighthouse-geth"
  "vc-1-geth-lighthouse"
  "contracts-001"
  "postgres-001"
  "agglayer"
  "cdk-erigon-sequencer-001"
  "zkevm-pool-manager-001"
  "cdk-erigon-rpc-001"
  "aggkit-001"
  "aggkit-001-bridge"
  "zkevm-bridge-service-001"
  "agglogger-001"
  "agglayer-dashboard"
)

SERVICE_START_DELAYS=(
  "el-1-geth-lighthouse:4"
  "cl-1-lighthouse-geth:4"
  "vc-1-geth-lighthouse:4"
  "contracts-001:2"
  "postgres-001:3"
  "agglayer:4"
  "cdk-erigon-sequencer-001:6"
  "zkevm-pool-manager-001:3"
  "cdk-erigon-rpc-001:5"
  "aggkit-001:4"
  "aggkit-001-bridge:4"
  "zkevm-bridge-service-001:4"
  "agglogger-001:2"
  "agglayer-dashboard:2"
)

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

contains_exact() {
  local needle="$1"
  shift
  local item

  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

service_delay() {
  local service_id="$1"
  local item

  for item in "${SERVICE_START_DELAYS[@]}"; do
    if [[ "${item%%:*}" == "$service_id" ]]; then
      printf '%s\n' "${item##*:}"
      return 0
    fi
  done

  printf '2\n'
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [enclave-name] [enclave-uuid]

Examples:
  $(basename "$0")
  $(basename "$0") cdk
  $(basename "$0") cdk 19bf978b62c6459598f5fb26a9f4c7f9

Notes:
  - Defaults enclave name to 'cdk'
  - Starts the enclave's existing long-running Docker containers directly
  - Starts core CDK services first, then resumes additional user-service containers
  - Skips Kurtosis helper/job containers that are not tagged as user services
  - Repairs the Kurtosis logs collector if it crashes on stale Fluent Bit backlog files
EOF
}

resolve_uuid_from_network() {
  local network_name="$1"
  local enclave_uuid

  enclave_uuid="$(
    docker network inspect "$network_name" \
      --format '{{ index .Labels "com.kurtosistech.enclave-id" }}'
  )"

  if [[ -n "$enclave_uuid" && "$enclave_uuid" != "<no value>" ]]; then
    printf '%s\n' "$enclave_uuid"
    return 0
  fi

  enclave_uuid="$(
    docker network inspect "$network_name" \
      --format '{{ index .Labels "kurtosis_enclave_uuid" }}'
  )"

  if [[ -n "$enclave_uuid" && "$enclave_uuid" != "<no value>" ]]; then
    printf '%s\n' "$enclave_uuid"
    return 0
  fi

  return 1
}

repair_logs_collector_backlog() {
  local collector_volume="$1"

  log "Clearing stale Fluent Bit backlog files from $collector_volume"
  docker run --rm -v "${collector_volume}:/data" alpine \
    sh -c 'rm -f /data/storage/forward.0/*.flb && ls -la /data/storage/forward.0'
}

start_logs_collector() {
  local collector_container="$1"
  local collector_volume="$2"

  if ! docker ps -a --format '{{.Names}}' | grep -Fxq "$collector_container"; then
    log "Logs collector container not found: $collector_container"
    return 0
  fi

  log "Starting logs collector: $collector_container"
  docker start "$collector_container" >/dev/null || true
  sleep 2

  if docker ps --format '{{.Names}}' | grep -Fxq "$collector_container"; then
    log "Logs collector is running"
    return 0
  fi

  log "Logs collector did not stay up, checking for Fluent Bit crash"
  if docker logs --tail 50 "$collector_container" 2>&1 | grep -q 'SIGSEGV'; then
    log "Detected Fluent Bit crash; repairing collector backlog"
    docker stop "$collector_container" >/dev/null 2>&1 || true
    repair_logs_collector_backlog "$collector_volume"
    docker start "$collector_container" >/dev/null
    sleep 2
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$collector_container"; then
    log "Logs collector recovered successfully"
  else
    die "Logs collector is still not running: $collector_container"
  fi
}

start_user_services() {
  local enclave_uuid="$1"
  local service_ids
  local ordered_containers=()
  local additional_containers=()
  local container_name
  local service_name
  local delay_seconds

  service_ids="$(
    docker ps -a \
      --filter "label=com.kurtosistech.enclave-id=${enclave_uuid}" \
      --filter "label=com.kurtosistech.container-type=user-service" \
      --format '{{.Label "com.kurtosistech.id"}}'
  )"

  [[ -n "$service_ids" ]] || die "No user-service containers found for enclave UUID ${enclave_uuid}"

  for service_name in "${STARTUP_SERVICE_ORDER[@]}"; do
    container_name="$(
      docker ps -a \
        --filter "label=com.kurtosistech.enclave-id=${enclave_uuid}" \
        --filter "label=com.kurtosistech.container-type=user-service" \
        --filter "label=com.kurtosistech.id=${service_name}" \
        --format '{{.Names}}' \
        | head -n 1
    )"

    if [[ -n "$container_name" ]]; then
      ordered_containers+=("$container_name")
    fi
  done

  while IFS= read -r service_name; do
    [[ -n "$service_name" ]] || continue

    if contains_exact "$service_name" "${STARTUP_SERVICE_ORDER[@]}"; then
      continue
    fi

    container_name="$(
      docker ps -a \
        --filter "label=com.kurtosistech.enclave-id=${enclave_uuid}" \
        --filter "label=com.kurtosistech.container-type=user-service" \
        --filter "label=com.kurtosistech.id=${service_name}" \
        --format '{{.Names}}' \
        | head -n 1
    )"

    if [[ -n "$container_name" ]]; then
      additional_containers+=("$container_name")
    fi
  done <<< "$service_ids"

  [[ ${#ordered_containers[@]} -gt 0 ]] || die "No restartable long-running services found for enclave UUID ${enclave_uuid}"

  if [[ ${#additional_containers[@]} -gt 0 ]]; then
    log "Additional user-service containers queued after core services:"
    for container_name in "${additional_containers[@]}"; do
      log "  - $container_name"
    done
  fi

  for container_name in "${ordered_containers[@]}"; do
    service_name="$(
      docker inspect "$container_name" \
        --format '{{ index .Config.Labels "com.kurtosistech.id" }}'
    )"

    log "Starting service container: $container_name"
    docker start "$container_name" >/dev/null || log "WARN: failed to start $container_name"

    delay_seconds="$(service_delay "$service_name")"
    sleep "$delay_seconds"
  done

  for container_name in "${additional_containers[@]}"; do
    service_name="$(
      docker inspect "$container_name" \
        --format '{{ index .Config.Labels "com.kurtosistech.id" }}'
    )"

    log "Starting additional service container: $container_name"
    docker start "$container_name" >/dev/null || log "WARN: failed to start $container_name"

    delay_seconds="$(service_delay "$service_name")"
    sleep "$delay_seconds"
  done
}

retry_core_services() {
  local enclave_uuid="$1"
  local attempt
  local service_name
  local container_name
  local delay_seconds

  for attempt in 1 2 3; do
    log "Retry pass ${attempt} for managed services"
    for service_name in "${STARTUP_SERVICE_ORDER[@]}"; do
      container_name="$(
        docker ps -a \
          --filter "label=com.kurtosistech.enclave-id=${enclave_uuid}" \
          --filter "label=com.kurtosistech.container-type=user-service" \
          --filter "label=com.kurtosistech.id=${service_name}" \
          --format '{{.Names}}' \
          | head -n 1
      )"

      [[ -n "$container_name" ]] || continue

      if docker ps --format '{{.Names}}' | grep -Fxq "$container_name"; then
        continue
      fi

      log "Retrying service container: $container_name"
      docker start "$container_name" >/dev/null || log "WARN: failed to restart $container_name"
      delay_seconds="$(service_delay "$service_name")"
      sleep "$delay_seconds"
    done
  done
}

print_summary() {
  local enclave_uuid="$1"

  log "Current enclave container status:"
  docker ps -a \
    --filter "label=com.kurtosistech.enclave-id=${enclave_uuid}" \
    --format 'table {{.Names}}\t{{.Status}}'
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd docker

  if [[ -z "$ENCLAVE_UUID" ]]; then
    ENCLAVE_UUID="$(resolve_uuid_from_network "${NETWORK_PREFIX}${ENCLAVE_NAME}" || true)"
  fi

  [[ -n "$ENCLAVE_UUID" ]] || die "Could not resolve enclave UUID for enclave '${ENCLAVE_NAME}'. Pass it as the second argument."

  local collector_container="${LOG_COLLECTOR_CONTAINER_PREFIX}${ENCLAVE_UUID}"
  local collector_volume="${LOG_COLLECTOR_VOLUME_PREFIX}${ENCLAVE_UUID}"

  log "Enclave name: $ENCLAVE_NAME"
  log "Enclave UUID: $ENCLAVE_UUID"

  start_logs_collector "$collector_container" "$collector_volume"
  start_user_services "$ENCLAVE_UUID"
  retry_core_services "$ENCLAVE_UUID"
  print_summary "$ENCLAVE_UUID"

  log "Recovery complete"
}

main "$@"
