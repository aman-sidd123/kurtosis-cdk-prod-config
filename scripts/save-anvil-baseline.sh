#!/usr/bin/env bash
set -euo pipefail

ENCLAVE="${1:-cdk}"
BASE_DIR="${2:-./artifacts/preprod-baseline/anvil-full}"
PUBLIC_CONFIG="${3:-./full-minimal-anvil.yml}"
PRIVATE_CONFIG="${4:-./anvil-preprod.private.yml}"

OUTPUT_ARTIFACT="anvil-full-output"
KEYSTORES_ARTIFACT="anvil-full-keystores"

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
}

require_cmd kurtosis
require_cmd cp
require_cmd mkdir

mkdir -p "$BASE_DIR/output"
mkdir -p "$BASE_DIR/keystores"
mkdir -p "$BASE_DIR/config"

echo "Storing service files from enclave '$ENCLAVE'..."
kurtosis files storeservice --name "$OUTPUT_ARTIFACT" "$ENCLAVE" contracts-001 /opt/output
kurtosis files storeservice --name "$KEYSTORES_ARTIFACT" "$ENCLAVE" contracts-001 /opt/keystores

echo "Downloading artifacts into '$BASE_DIR'..."
kurtosis files download "$ENCLAVE" "$OUTPUT_ARTIFACT" "$BASE_DIR/output"
kurtosis files download "$ENCLAVE" "$KEYSTORES_ARTIFACT" "$BASE_DIR/keystores"

if [[ -f "$PUBLIC_CONFIG" ]]; then
    cp "$PUBLIC_CONFIG" "$BASE_DIR/config/"
fi

if [[ -f "$PRIVATE_CONFIG" ]]; then
    cp "$PRIVATE_CONFIG" "$BASE_DIR/config/"
fi

NOTES_FILE="$BASE_DIR/notes.txt"
{
    echo "Anvil Full Baseline Snapshot"
    echo "==========================="
    echo
    echo "Saved at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Enclave: $ENCLAVE"
    echo "Output artifact: $OUTPUT_ARTIFACT"
    echo "Keystore artifact: $KEYSTORES_ARTIFACT"
    echo
    echo "Included paths:"
    echo "- output/"
    echo "- keystores/"
    echo "- config/"
    echo
    echo "Core services:"
    for service in \
        agglayer \
        cdk-erigon-sequencer-001 \
        cdk-erigon-rpc-001 \
        cdk-node-001 \
        zkevm-pool-manager-001 \
        zkevm-bridge-service-001 \
        postgres-001
    do
        echo
        echo "[$service]"
        kurtosis service inspect "$ENCLAVE" "$service" 2>&1 || true
    done
} >"$NOTES_FILE"

echo "Baseline snapshot saved to: $BASE_DIR"
echo "Notes written to: $NOTES_FILE"
