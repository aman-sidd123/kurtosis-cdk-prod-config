#!/usr/bin/env bash

set -e

# Generate mnemonic
MNEMONIC=$(cast wallet new-mnemonic | awk '/Phrase:/{getline; print}' | xargs)

# L1 private key (index 0)
L1_PK=$(cast wallet derive-private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)

# Random password
L2_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Roles
ROLES=("sequencer" "aggregator" "admin" "dac" "sovereignadmin" "claimsponsor")

echo "l1_preallocated_mnemonic: \"$MNEMONIC\""
echo "l1_preallocated_private_key: \"$L1_PK\""
echo ""
echo "l2_keystore_password: \"$L2_PASSWORD\""
echo ""

# Generate accounts
for i in "${!ROLES[@]}"; do
  ROLE=${ROLES[$i]}
  INDEX=$((i+1))

  PK=$(cast wallet derive-private-key --mnemonic "$MNEMONIC" --mnemonic-index $INDEX)
  ADDR=$(cast wallet address --private-key $PK)

  echo "l2_${ROLE}_address: \"$ADDR\""
  echo "l2_${ROLE}_private_key: \"$PK\""
  echo ""
done