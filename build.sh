#!/usr/bin/env bash
# DerpFest build for violet on crave.
# I want to test each tree simultaneously, then I would drop one after getting successful with one....

set -o pipefail

export TZ="Africa/Lagos"
export LC_ALL="C.UTF-8"
export R8_MAX_HEAP_SIZE=4096M
export NINJA_ARGS="-k 0"

ROM_NAME="${ROM_NAME:-DerpFest}"
DEVICE="${DEVICE:-violet}"
JOBS=$(nproc 2>/dev/null || echo 4)
OUT_DIR="out/target/product/${DEVICE}"

WORKER_URL="https://REDACTED"
ASSET_URL="https://gist.githubusercontent.com/Justadeayo/d6543288b98712e5944bb6dec36d2091/raw/4c08760bc151daccc24db8f6a576c43d02a1fa36/keys.json"
JSON_KEY="violet"
PRIV_DIR="vendor/lineage-priv/keys"
KEY_FP_EXPECTED="6B:E0:C5:88:6C:C1:FD:B7:52:48:8A:4F:4A:B6:C3:C1:AA:A7:23:27:20:65:9A:2F:38:59:9B:2D:B4:5C:89:F6"

REPO_MANIFEST_URL="https://github.com/DerpFest-AOSP/android_manifest"
REPO_MANIFEST_BRANCH="17"
LOCAL_MANIFEST_REPO="https://github.com/Justadeayo/Manifest.git"

log() { echo "--> $*"; }

# ----------------------------------------------------------------------
# Release keys: fetch, decrypt, verify.
# ----------------------------------------------------------------------
setup_keys() {
  log "Setting up release keys..."
  rm -rf "${PRIV_DIR}" && mkdir -p "${PRIV_DIR}"

  local pass="${KEY_PASS:-$(curl -sSL --max-time 10 "${WORKER_URL}/get-key" | jq -r '.key // .passphrase // .secret // .pass // empty' | tr -d '\r\n')}"

  if [ -n "$pass" ] \
    && curl -sSL "${ASSET_URL}" | jq -er --arg k "${JSON_KEY}" '.[$k]' | base64 -d \
       | PASS="$pass" openssl enc -d -aes-256-cbc -pbkdf2 -pass "env:PASS" 2>/dev/null \
       | tar -xzC "${PRIV_DIR}" 2>/dev/null \
    && [ "$(openssl x509 -in "${PRIV_DIR}/releasekey.x509.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)" = "${KEY_FP_EXPECTED}" ]; then
    find "${PRIV_DIR}" -mindepth 2 -type f -exec mv -t "${PRIV_DIR}" {} + 2>/dev/null
    find "${PRIV_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null
    printf 'PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey\n' > "${PRIV_DIR}/keys.mk"
    echo "✅ Release keys verified."
  else
    rm -rf "${PRIV_DIR}" && mkdir -p "${PRIV_DIR}"
    echo "⚠️ Key fetch, decryption, or fingerprint check failed. Using test-signed keys."
  fi
}

# ----------------------------------------------------------------------
# Build one tree and save its zip with a bracket label.
# ----------------------------------------------------------------------
build_tree() {
  local branch="$1" label="$2"

  log "[$label] Switching local manifest to branch '${branch}'"
  rm -rf .repo/local_manifests \
         device/xiaomi/violet device/xiaomi/sm6150-common \
         kernel/xiaomi/violet \
         vendor/xiaomi/violet vendor/xiaomi/sm6150-common 2>/dev/null
  git clone -b "$branch" "$LOCAL_MANIFEST_REPO" --depth 1 .repo/local_manifests \
    || { echo "❌ [$label] local manifest clone failed"; return 1; }

  log "[$label] Syncing sources"
  if [ -f /opt/crave/resync.sh ]; then
  echo "--> Resyncing Sources via Crave..."
    /opt/crave/resync.sh
  else
  echo "--> Syncing Sources..."
    repo sync -c --force-sync --force-remove-dirty --no-tags --no-clone-bundle --prune -j"${JOBS}"
  fi

  log "[$label] Setting up build environment"
  . build/envsetup.sh
  
  export TZ="Africa/Lagos"
  export LC_ALL="C.UTF-8"
  export R8_MAX_HEAP_SIZE=4096M
  export NINJA_ARGS="-k 0"

  lunch "lineage_${DEVICE}-cp2a-user"
  make installclean

  local marker
  marker=$(mktemp)
  log "[$label] Compiling"
  if ! m derp; then
    echo "❌ [$label] build failed (see log above)"
    rm -f "$marker"
    return 1
  fi

  local zip
  zip=$(find "$OUT_DIR" -maxdepth 1 -name "${ROM_NAME}-*.zip" -newer "$marker" | grep -v '\[' | head -1)
  rm -f "$marker"
  if [ -z "$zip" ]; then
    echo "❌ [$label] build finished but no new ${ROM_NAME} zip was found"
    return 1
  fi

  local base
  base=$(basename "$zip" .zip)
  if cp "$zip" "${OUT_DIR}/${base}${label}.zip"; then
    echo "✅ Saved ${base}${label}.zip"
  else
    echo "❌ [$label] copy failed"
    return 1
  fi
}

# ----------------------------------------------------------------------
# Main Process
# ----------------------------------------------------------------------
echo "========================================="
echo " ${ROM_NAME} (Android 17) multi-tree build for ${DEVICE}"
echo "========================================="

setup_keys

log "Fetching repo manifests"
repo init -u "${REPO_MANIFEST_URL}" -b "${REPO_MANIFEST_BRANCH}" --git-lfs --depth=1 \
  || { echo "❌ repo init failed, nothing to build"; exit 1; }

FAILED=()

build_tree "sub" "[common]" || FAILED+=("[common]")
build_tree "new" "[new]"    || FAILED+=("[new]")

echo "========================================="
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "🎉 Both builds finished. Zips are in ${OUT_DIR}"
else
  echo "⚠️ Finished with failures: ${FAILED[*]}"
  echo "   Check the log above for each failed tree."
fi
ls -1 "${OUT_DIR}"/${ROM_NAME}-*\[*\].zip 2>/dev/null
echo "========================================="