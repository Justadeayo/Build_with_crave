#!/usr/bin/env bash

# ==============================================================================
# keys.sh — RELEASE KEYS
# ==============================================================================

ASSET_URL="https://gist.githubusercontent.com/Justadeayo/d6543288b98712e5944bb6dec36d2091/raw/4c08760bc151daccc24db8f6a576c43d02a1fa36/keys.json"
JSON_KEY="violet"
PRIV_DIR="vendor/lineage-priv/keys"
KEY_FP_EXPECTED="6B:E0:C5:88:6C:C1:FD:B7:52:48:8A:4F:4A:B6:C3:C1:AA:A7:23:27:20:65:9A:2F:38:59:9B:2D:B4:5C:89:F6"

KEY_SOURCE=""
KEY_COUNT=0

key_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

own_keys_ok() {
  [ -f "${PRIV_DIR}/releasekey.pk8" ] \
    && [ "$(key_fingerprint "${PRIV_DIR}/releasekey.x509.pem")" = "${KEY_FP_EXPECTED}" ]
}

load_keys() {
  local pass tmp

  pass="${KEY_PASS}"

  if [ -z "${pass}" ]; then
    echo "⚠️ No key passphrase available (KEY_PASS unset)."
    return 1
  fi

  tmp="$(mktemp)"
  if ! curl -fsSL "${ASSET_URL}" 2>/dev/null \
    | jq -er --arg k "${JSON_KEY}" '.[$k] // empty' 2>/dev/null \
    | base64 -d > "${tmp}" 2>/dev/null || [ ! -s "${tmp}" ]; then
    rm -f "${tmp}"
    echo "⚠️ Could not fetch or decode '${JSON_KEY}' from the gist."
    return 1
  fi

  mkdir -p "${PRIV_DIR}"
  if ! KEY_PASS="${pass}" openssl enc -d -aes-256-cbc -pbkdf2 -pass env:KEY_PASS -in "${tmp}" 2>/dev/null \
    | tar -xzC "${PRIV_DIR}" 2>/dev/null; then
    rm -f "${tmp}"
    echo "⚠️ Decryption failed. Wrong passphrase or corrupted key archive."
    return 1
  fi
  rm -f "${tmp}"

  find "${PRIV_DIR}" -mindepth 2 -type f -exec mv -t "${PRIV_DIR}" {} + 2>/dev/null || true
  find "${PRIV_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

  if own_keys_ok; then
    return 0
  fi
  echo "⚠️ Extracted key fingerprint does not match KEY_FP_EXPECTED."
  return 1
}

setup_signing_keys() {
  KEY_SOURCE=""
  echo "--> Checking release keys..."
  if own_keys_ok; then
    KEY_SOURCE="on disk"
  elif load_keys; then
    KEY_SOURCE="gist fallback"
  fi

  if [ -n "${KEY_SOURCE}" ]; then
    printf 'PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey\n' > "${PRIV_DIR}/keys.mk"
    KEY_COUNT=$(ls -1 "${PRIV_DIR}"/*.pk8 2>/dev/null | wc -l)
    SM="Custom"
    echo "✅ Release key verified (${KEY_SOURCE}). Building personal release-signed."
    tg_send "🔑 *Signing:* personal release key (${KEY_SOURCE}, fingerprint verified)"
  else
    rm -f "${PRIV_DIR}/keys.mk"
    KEY_COUNT=0
    SM="Default"
    echo "⚠️ No verified release key. Building with the test key."
    tg_send "⚠️ *Release key unavailable.* Building test-signed (not dirty-flash compatible with release builds)."
  fi
}
