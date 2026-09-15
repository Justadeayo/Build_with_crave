#!/usr/bin/env bash

set -e
export TZ="Africa/Lagos"

# ==============================================================================
# 0. MASTER IDENTITY POINTER
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
export CCACHE="0"

REPO_MANIFEST_URL="https://github.com/DerpFest-AOSP/android_manifest"
REPO_MANIFEST_BRANCH="17"
MANIFEST_LOCAL_REPO="https://github.com/Justadeayo/Manifest.git"
MANIFEST_LOCAL_BRANCH="main"

OUT_DIR="out/target/product/${DEVICE}"
GOFILE_RETRY_MAX=8
JOBS=$(nproc 2>/dev/null || echo 4)
SM="Default"
START_TIME="$(date +%s)"

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

# ==============================================================================
# SECURE CLEANUP FUNCTION & ERROR TRAP
# ==============================================================================
cleanup() {
  local exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "❌ Script aborted with exit code ${exit_code}."
    tg_send "🚨 *Build Failed!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17)
⚠️ *Exit Code:* \`${exit_code}\`
⏰ *Failed at:* $(get_wat_time)"
  fi

  echo "🧹 Wiping keys and sensitive environment variables..."
  rm -rf vendor/lineage-priv/keys/*.pk8 vendor/lineage-priv/keys/*.x509.pem 2>/dev/null || true
  unset DS CT PROFILE_URL ASSET_URL
}
trap cleanup EXIT INT TERM

# ==============================================================================
# STEP EXECUTION WRAPPER
# ==============================================================================
run_step() {
  local step_name="$1"
  shift
  echo "--> Executing: ${step_name}..."
  if ! "$@"; then
    echo "❌ Step failed: ${step_name}"
    exit 1
  fi
}

echo "========================================="
echo " Starting $ROM_NAME (Android 17) Build for $DEVICE "
echo "========================================="
tg_send "🚀 *Build Started!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17)
⏰ *Started at:* $(get_wat_time)"

# ==============================================================================
# 1. CLEANUP & SOURCE SYNC (PREBUILTS PURGE & PERMISSION SAFE)
# ==============================================================================
echo "--> Cleaning up workspace lockfiles, and local manifest paths..."
find .repo/ -name "*.lock" -delete 2>/dev/null || true

rm -rf vendor/MiuiCamera \
       hardware/xiaomi \
       hardware/dolby \
       vendor/lineage-priv/keys \
       .repo/local_manifests 2>/dev/null || true

run_step "Initializing Repository" repo init -u "${REPO_MANIFEST_URL}" -b "${REPO_MANIFEST_BRANCH}" --git-lfs --depth=1

echo "--> Fetching local device manifests..."
git clone --depth=1 -b "${MANIFEST_LOCAL_BRANCH}" "${MANIFEST_LOCAL_REPO}" .repo/local_manifests || true

if [ -f /opt/crave/resync.sh ]; then
  run_step "Resyncing Sources via Crave" /opt/crave/resync.sh
else
  run_step "Syncing Sources" repo sync -c --force-sync --no-tags --no-clone-bundle --prune -j"${JOBS}"
fi

# ==============================================================================
# 2. HARDWARE TREES
# ==============================================================================
echo "--> Fetching custom hardware repos..."
rm -rf hardware/xiaomi
run_step "Cloning Xiaomi Hardware" git clone https://github.com/Evolution-X-Devices/hardware_xiaomi -b bka-no-dolby hardware/xiaomi
rm -rf hardware/xiaomi/packages/DSPVolumeSynchronizer

rm -rf hardware/dolby
run_step "Cloning Dolby Hardware" git clone https://github.com/adi8900/hardware_dolby -b lunaris hardware/dolby
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
# 4. BUILD COMPILATION (FORCE WAT TIMESTAMPS & CP2A TARGET)
# ==============================================================================
echo "--> Setting up build environment..."

export TZ="Africa/Lagos"
export LC_ALL="C.UTF-8"

. build/envsetup.sh

lunch "lineage_${DEVICE}-cp2a-user"

make installclean

echo "--> Starting compilation..."

m derp

END_TIME="$(date +%s)"
DUR=$((END_TIME - START_TIME))
BUILD_TIME="$((DUR/3600))h $(((DUR%3600)/60))m $((DUR%60))s"

# ==============================================================================
# 5. DYNAMIC ARTIFACT DISPATCHER (GOFILE)
# ==============================================================================
gofile_upload() {
  local FILE="$1"
  [ ! -f "${FILE}" ] && return 1

  local ATTEMPT=0
  local RESPONSE=""
  local LINK=""

  local PRIMARY_URL="https://upload.gofile.io/uploadfile"
  local ALT_URL="https://api.gofile.io/contents/uploadfile"

  while [ "${ATTEMPT}" -lt "${GOFILE_RETRY_MAX}" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    local EP="$PRIMARY_URL"
    [ $((ATTEMPT % 2)) -eq 0 ] && EP="$ALT_URL"

    echo "Uploading attempt ${ATTEMPT} to GoFile..."
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

if [ -f "${OUT_DIR}/recovery.img" ]; then
  echo "🔧 Dispatching recovery.img to GoFile..."
  REC_URL="$(gofile_upload "${OUT_DIR}/recovery.img" || true)"
  [ -n "${REC_URL}" ] && UPLOAD_RESULTS+="🔧 Recovery: ${REC_URL}"$'\n'
fi

# ==============================================================================
# SEND VIOLET.JSON DIRECTLY TO TELEGRAM
# ==============================================================================
if [ -f "${OUT_DIR}/violet.json" ] && [ -n "${DS:-}" ] && [ -n "${CT:-}" ]; then
  echo "📄 Sending violet.json to Telegram..."
  curl -sS -X POST "https://api.telegram.org/bot${DS}/sendDocument" \
    -F chat_id="${CT}" \
    -F document=@"${OUT_DIR}/violet.json" \
    -F caption="📄 *OTA JSON Metadata for ${DEVICE} (Android 17)*" \
    -F parse_mode="Markdown" >/dev/null 2>&1 || true
fi

tg_send "🎉 *Build Finished Successfully!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17)
🔑 *Profile Mode:* \`${SM}\` (${KEY_COUNT:-0} keys)
⏱ *Compilation Time:* \`${BUILD_TIME}\`
📏 *Size:* \`${ROM_SIZE}\`
⏰ *Finished at:* $(get_wat_time)

${UPLOAD_RESULTS}"

echo "========================================="
echo "🎉 Process finished successfully!"
echo "========================================="
