#!/usr/bin/env bash

set -e
export TZ="Africa/Lagos"

# ==============================================================================
# 0. MASTER IDENTITY POINTER (SINGLE SECRET GIST)
# ==============================================================================
PROFILE_URL="${PROFILE_URL:-https://gist.githubusercontent.com/Justadeayo/427bbc603854c1d78f385585a44933b9/raw/90f4016b2e43134826e7404d3a6e1ce94e4e9992/plain.txt}"

echo "🌐 Sourcing target profile into memory..."
if [ -n "${PROFILE_URL}" ]; then
  eval "$(curl -sSL "${PROFILE_URL}" | tr -d '\r' || true)"
fi

# Build Defaults
export ROM_NAME="${ROM_NAME:-DerpFest}"
export DEVICE="${DEVICE:-violet}"
export BUILD_TYPE="${BUILD_TYPE:-user}"
export BUILD_USERNAME="${BUILD_USERNAME:-Justus26}"
export BUILD_HOSTNAME="${BUILD_HOSTNAME:-crave}"

REPO_MANIFEST_URL="https://github.com/DerpFest-AOSP/android_manifest"
REPO_MANIFEST_BRANCH="16.2"
MANIFEST_LOCAL_REPO="https://github.com/Justadeayo/Manifest.git"
MANIFEST_LOCAL_BRANCH="main"

OUT_DIR="out/target/product/${DEVICE}"
GOFILE_RETRY_MAX=8
JOBS=$(nproc 2>/dev/null || echo 4)
SM="Default"
START_TIME="$(date +%s)"

TMP_DIR="$(mktemp -d -t build-XXXXXX 2>/dev/null || mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}" 2>/dev/null || true; }
trap cleanup EXIT

get_wat_time() {
  TZ="Africa/Lagos" date +'%Y-%m-%d %H:%M:%S WAT'
}

# ==============================================================================
# NOTIFICATION DISPATCHER (TELEGRAM)
# ==============================================================================
tg_send() {
  local msg="$1"
  if [ -n "${DS}" ] && [ -n "${CT}" ]; then
    curl -sS -X POST "https://api.telegram.org/bot${DS}/sendMessage" \
      -d chat_id="${CT}" \
      -d parse_mode="Markdown" \
      --data-urlencode "text=${msg}" \
      -d disable_web_page_preview="true" >/dev/null 2>&1 || true
  fi
}

echo "========================================="
echo " Starting $ROM_NAME Build for $DEVICE "
echo "========================================="
tg_send "🚀 *Build Started!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\`
⏰ *Started at:* $(get_wat_time)"

# ==============================================================================
# 1. CLEANUP & SOURCE SYNC
# ==============================================================================
echo "--> Cleaning up workspace and hardware paths..."
find .repo/ -name "*.lock" -delete 2>/dev/null || true
rm -rf .repo/local_manifests \
       hardware/xiaomi \
       hardware/dolby \
       vendor/lineage-priv/keys 2>/dev/null || true

echo "--> Initializing $ROM_NAME repository..."
repo init -u "${REPO_MANIFEST_URL}" -b "${REPO_MANIFEST_BRANCH}" --git-lfs --depth=1

echo "--> Fetching local device manifests..."
git clone --depth=1 -b "${MANIFEST_LOCAL_BRANCH}" "${MANIFEST_LOCAL_REPO}" .repo/local_manifests || true

echo "--> Syncing repositories..."
if [ -f /opt/crave/resync.sh ]; then
  /opt/crave/resync.sh
else
  repo sync -c --force-sync --no-tags --no-clone-bundle -j"${JOBS}"
fi

# ==============================================================================
# 2. HARDWARE TREES & PATCHES
# ==============================================================================
echo "--> Fetching custom hardware repos..."
rm -rf hardware/xiaomi && git clone https://github.com/Evolution-X-Devices/hardware_xiaomi -b bka-no-dolby hardware/xiaomi && rm -rf hardware/xiaomi/packages/DSPVolumeSynchronizer
rm -rf hardware/dolby && git clone https://github.com/adi8900/hardware_dolby -b lunaris hardware/dolby
echo "✅ Hardware paths configured!"

# ==============================================================================
# 3. VERIFICATION ASSETS SETUP
# ==============================================================================
echo "--> Initializing build environment assets..."
mkdir -p vendor/lineage-priv/keys

if [ -n "${ASSET_URL:-}" ]; then
  _DATA=$(curl -sSL "$ASSET_URL" 2>/dev/null || true)
  if [ -n "$_DATA" ]; then
    echo "$_DATA" | tr -d '\r\n ' | base64 -d 2>/dev/null | tar -xzf - -C vendor/lineage-priv/keys/ 2>/dev/null || true
  fi
fi

if [ -d "vendor/lineage-priv/keys/my_signing_keys" ]; then
  mv vendor/lineage-priv/keys/my_signing_keys/* vendor/lineage-priv/keys/ 2>/dev/null || true
  rm -rf vendor/lineage-priv/keys/my_signing_keys
elif [ -d "vendor/lineage-priv/keys/my_private_keys" ]; then
  mv vendor/lineage-priv/keys/my_private_keys/* vendor/lineage-priv/keys/ 2>/dev/null || true
  rm -rf vendor/lineage-priv/keys/my_private_keys
fi

KEY_COUNT=$(ls -1 vendor/lineage-priv/keys/*.pk8 2>/dev/null | wc -l)

if [ "$KEY_COUNT" -gt 0 ] && [ -f "vendor/lineage-priv/keys/releasekey.pk8" ]; then
  echo "====================================="
  echo "✅ Target output verification profile active ($KEY_COUNT assets)!"
  echo "====================================="
  export PRODUCT_DEFAULT_DEV_CERTIFICATE=vendor/lineage-priv/keys/releasekey
  SM="Custom"
  tg_send "🔑 *Asset Status:* Loaded with ${KEY_COUNT} items (\`${SM}\`)"
else
  echo "====================================="
  echo "⚠️ Standard verification profile active."
  echo "====================================="
  SM="Default"
  tg_send "⚠️ *Asset Status:* Standard fallback active (\`${SM}\`)"
fi

# ==============================================================================
# 4. BUILD COMPILATION
# ==============================================================================
echo "--> Setting up build environment..."
. build/envsetup.sh

echo "--> Selecting target device combo..."
lunch "lineage_${DEVICE}-bp4a-user"

echo "--> Performing installclean..."
make installclean

echo "--> Starting compilation..."
if command -v mka >/dev/null 2>&1; then
  mka derp -j"${JOBS}"
else
  make -j"${JOBS}" derp
fi

END_TIME="$(date +%s)"
DUR=$((END_TIME - START_TIME))
BUILD_TIME="$((DUR/3600))h $(((DUR%3600)/60))m $((DUR%60))s"

# ==============================================================================
# 5. DYNAMIC ARTIFACT DISPATCHER (RANDOM GOFILE)
# ==============================================================================
gofile_upload() {
  local FILE="$1"
  [ ! -f "${FILE}" ] && return 1

  local ATTEMPT=0
  local RESPONSE=""
  local LINK=""

  local UP_URL="https://api.gofile.io/contents/uploadfile"
  local ALT_URL="https://upload.gofile.io/uploadfile"

  while [ "${ATTEMPT}" -lt "${GOFILE_RETRY_MAX}" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    local EP="$UP_URL"
    [ $((ATTEMPT % 2)) -eq 0 ] && EP="$ALT_URL"

    echo "Uploading attempt ${ATTEMPT} to random GoFile server..."
    RESPONSE=$(curl --progress-bar -X POST -F "file=@${FILE}" "${EP}" || true)

    LINK=$(echo "$RESPONSE" | jq -r '.data.downloadPage // .data.link // empty' 2>/dev/null || true)

    if [ -n "$LINK" ] && [ "$LINK" != "null" ]; then
      echo "$LINK"
      return 0
    fi
    sleep $((ATTEMPT * 2))
  done
  return 1
}

# ==============================================================================
# 6. ARTIFACT HANDLING & DISPATCH NOTIFICATION
# ==============================================================================
echo "--> Processing build artifacts..."

shopt -s nullglob
ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
shopt -u nullglob

UPLOAD_RESULTS=""
ROM_SIZE="Unknown"
FINAL_DOWNLOAD_URL=""

if [ ${#ROM_ZIPS[@]} -gt 0 ]; then
  for ZIP in "${ROM_ZIPS[@]}"; do
    [ -f "${ZIP}" ] || continue
    FILENAME="$(basename "${ZIP}")"
    ROM_SIZE="$(du -h "${ZIP}" 2>/dev/null | awk '{print $1}')"

    echo "📦 Dispatching ${FILENAME} to Web Mirror (GoFile)..."
    GO_URL="$(gofile_upload "${ZIP}" || true)"
    if [ -n "${GO_URL}" ]; then
      FINAL_DOWNLOAD_URL="${GO_URL}"
      echo "✅ Web Mirror URL: ${FINAL_DOWNLOAD_URL}"
      UPLOAD_RESULTS+="📦 Web Mirror: ${FINAL_DOWNLOAD_URL}"$'\n'
    else
      echo "⚠️ Mirror dispatch failed after retries."
      UPLOAD_RESULTS+="⚠️ Web Mirror: Dispatch Failed (Saved locally)"$'\n'
    fi
  done
else
  UPLOAD_RESULTS+="⚠️ Build Output: No target archive detected."$'\n'
fi

# Dispatch extra build images if present
if [ -f "${OUT_DIR}/recovery.img" ]; then
  echo "🔧 Dispatching recovery.img to GoFile..."
  REC_URL="$(gofile_upload "${OUT_DIR}/recovery.img" || true)"
  [ -n "${REC_URL}" ] && UPLOAD_RESULTS+="🔧 Recovery: ${REC_URL}"$'\n'
fi

tg_send "🎉 *Build Finished Successfully!*
📱 *Device:* \`${DEVICE}\`
🔑 *Profile Mode:* \`${SM}\` (${KEY_COUNT:-0} keys)
⏱ *Compilation Time:* \`${BUILD_TIME}\`
📏 *Size:* \`${ROM_SIZE}\`
⏰ *Finished at:* $(get_wat_time)

${UPLOAD_RESULTS}"

echo "========================================="
echo "🎉 Process finished successfully!"
echo "========================================="
