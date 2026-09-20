#!/usr/bin/env bash

set -e
export TZ="Africa/Lagos"

# ==============================================================================
# NOTIFICATION & KEY RELAY CONFIGURATION
# ==============================================================================
WORKER_URL="https://crave-ok.justadeayo.workers.dev"

tg_send() {
  local msg="$1"
  if [ -n "${WORKER_URL}" ]; then
    curl -sS -X POST "${WORKER_URL}" \
      --data-urlencode "text=${msg}" >/dev/null 2>&1 || true
  fi
}

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
GDRIVE_REMOTE="${GDRIVE_REMOTE:-${DEVICE}:DerpFest_Builds}"
JOBS=$(nproc 2>/dev/null || echo 4)
SM="Default"
START_TIME="$(date +%s)"

get_wat_time() {
  TZ="Africa/Lagos" date +'%Y-%m-%d %H:%M:%S WAT'
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

  echo "🧹 Wiping key assets from memory..."
  rm -rf vendor/lineage-priv/keys/*.pk8 vendor/lineage-priv/keys/*.x509.pem 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ==============================================================================
# STEP EXECUTION WRAPPER
# ==============================================================================
run_step() {
  local step_name="$1"
  shift
  echo "--> Executing: ${step_name}..."
  tg_send "▶️ *${step_name}*
⏰ $(get_wat_time)"
  if ! "$@"; then
    echo "❌ Step failed: ${step_name}"
    tg_send "❌ *Step Failed:* ${step_name}
⏰ $(get_wat_time)"
    exit 1
  fi
  tg_send "✅ *${step_name}* — done
⏰ $(get_wat_time)"
}

echo "========================================="
echo " Starting $ROM_NAME (Android 17) Build for $DEVICE "
echo "========================================="
tg_send "🚀 *Build Started!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17)
⏰ *Started at:* $(get_wat_time)"

# ==============================================================================
# 1. CLEANUP & SOURCE SYNC
# ==============================================================================
echo "--> Wiping local git changes across all repos..."
repo forall -c 'git diff-index --quiet HEAD -- || (git reset --hard HEAD && git clean -fdx)' 2>/dev/null || true

echo "--> Cleaning up workspace lockfiles and local manifest paths..."
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
  run_step "Syncing Sources" repo sync -c --force-sync --force-remove-dirty --no-tags --no-clone-bundle --prune -j"${JOBS}"
fi

echo "--> Force-refreshing pinned local-manifest projects"
rm -rf kernel/xiaomi/violet device/xiaomi/violet vendor/xiaomi/violet
run_step "Force Re-sync (pinned projects)" repo sync --force-sync --force-remove-dirty --no-tags --no-clone-bundle -j"${JOBS}" \
  kernel/xiaomi/violet device/xiaomi/violet vendor/xiaomi/violet


BG_CLANG="clang-r584948"
CLANG_DIR="prebuilts/clang/host/linux-x86"
BG_PATH="${CLANG_DIR}/${BG_CLANG}"
: "${GOOGLE_CLANG_URL:=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"

clang_res()      { ls -d "$1"/lib/clang/*/ 2>/dev/null | head -1; }   # builtin-header dir
clang_complete() { [ -f "$(clang_res "$1")include/stdbool.h" ] && ls "$1"/lib/libclang.so* >/dev/null 2>&1; }

# fetch_bg_clang <url> <rev>: download into a scratch repo, swap in only if complete
fetch_bg_clang() {
  local url="$1" rev="$2" tmp i got=0
  tmp="$(mktemp -d "$(pwd)/.bgclang.XXXXXX")" || return 1
  echo "--> ${BG_CLANG} <- ${url} @ ${rev}"

  if git -C "${tmp}" init -q && git -C "${tmp}" remote add origin "${url}"; then
    for i in 1 2 3; do
      if git -C "${tmp}" fetch -q --depth=1 --filter=blob:none origin "${rev}"; then got=1; break; fi
      sleep $((i * 5))
    done
  fi

  if [ "${got}" = 1 ] \
     && git -C "${tmp}" sparse-checkout set "${BG_CLANG}" \
     && git -C "${tmp}" checkout -q FETCH_HEAD \
     && clang_complete "${tmp}/${BG_CLANG}"; then
    mv "${BG_PATH}" "${tmp}/prev" 2>/dev/null || true          # keep the old copy until the new one is in
    if mv "${tmp}/${BG_CLANG}" "${BG_PATH}"; then rm -rf "${tmp}"; return 0; fi
    if [ -d "${tmp}/prev" ]; then mv "${tmp}/prev" "${BG_PATH}"; fi   # roll back
  fi

  echo "⚠️ ${BG_CLANG}: download from ${url} @ ${rev} failed or incomplete"
  rm -rf "${tmp}"
  return 1
}

prepare_bindgen_clang() {
  local -a sources=()
  local url rev src res got_it=0

  # sources: manifest's remote + pinned rev first, Google main second
  read -r url rev < <(repo forall "${CLANG_DIR}" -c 'echo "$(git config --get "remote.$REPO_REMOTE.url") $REPO_RREV"' 2>/dev/null | tail -1) || true
  if [ -n "${url:-}" ] && [ -n "${rev:-}" ]; then sources+=("${url} ${rev}"); fi
  sources+=("${GOOGLE_CLANG_URL} main")

  for src in "${sources[@]}"; do
    read -r url rev <<<"${src}"
    if fetch_bg_clang "${url}" "${rev}"; then got_it=1; break; fi
  done

  if [ "${got_it}" != 1 ]; then
    if clang_complete "${BG_PATH}"; then
      echo "⚠️ All downloads failed - continuing with the workspace copy (it looks complete)"
      tg_send "⚠️ *${BG_CLANG} download failed* - building with the workspace copy"
    else
      echo "⚠️ All downloads failed and the workspace copy looks incomplete - continuing anyway"
      tg_send "⚠️ *${BG_CLANG} download failed and workspace copy looks incomplete* - continuing; bindgen may fail"
    fi
  fi

  # belt and braces: hand bindgen's libclang the resource dir explicitly (only if it is valid)
  res="$(clang_res "${BG_PATH}")"
  if [ -n "${res}" ] && [ -f "${res}include/stdbool.h" ]; then
    export BINDGEN_EXTRA_CLANG_ARGS="-resource-dir=$(pwd)/${res}"
    echo "✅ ${BG_CLANG} ready (${BINDGEN_EXTRA_CLANG_ARGS})"
  fi
  return 0
}

# called on the left of '||' so 'set -e' is off inside: nothing in here can abort the script
prepare_bindgen_clang || echo "⚠️ bindgen clang step hit an unexpected error - continuing to build"

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

echo "--> Ensuring kernel-specific clang (r416183b) is available..."
KERNEL_CLANG_DIR="prebuilts/clang/host/linux-x86/clang-r416183b"
if [ ! -x "${KERNEL_CLANG_DIR}/bin/clang" ]; then
  echo "--> clang-r416183b not found, fetching for kernel build..."
  git clone --depth=1 https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b.git "${KERNEL_CLANG_DIR}"
fi
file "${KERNEL_CLANG_DIR}/bin/clang"

# ==============================================================================
# 3. VERIFICATION ASSETS SETUP (IN-MEMORY AES-256 DECRYPTION)
# ==============================================================================
echo "--> Initializing build environment assets..."
mkdir -p vendor/lineage-priv/keys

ASSET_URL="${ASSET_URL:-https://gist.githubusercontent.com/Justadeayo/9f813a5fd4b35290aa666fac735fda4d/raw/32ac18aae99a1712e804d31ac0a02b767d915163/keys.json}"
JSON_KEY="my-signing-keys"  

KEY_COUNT=0

if [ -n "${ASSET_URL}" ]; then
  KEY_PASS=$(curl -sSL "${WORKER_URL}/get-key" || true)
  KEY_PASS=$(printf '%s' "${KEY_PASS}" | tr -d '\r\n' | sed -e 's/^ *//' -e 's/ *$//')

  if [ -n "${KEY_PASS}" ]; then
    echo "🔑 Passphrase received (${#KEY_PASS} chars) — decrypting verification assets..."

    KTMP="$(mktemp -d ./keydec.XXXXXX 2>/dev/null || echo "./keydec.$$")"
    mkdir -p "${KTMP}"
    DECRYPT_OK=0

    if curl -sSL "${ASSET_URL}" -o "${KTMP}/keys.json" && [ -s "${KTMP}/keys.json" ]; then
      if jq -e -r ".[\"${JSON_KEY}\"] // empty" "${KTMP}/keys.json" > "${KTMP}/keys.b64" 2>"${KTMP}/jq.err" \
         && [ -s "${KTMP}/keys.b64" ]; then
        if base64 -d < "${KTMP}/keys.b64" > "${KTMP}/keys.bin" 2>"${KTMP}/b64.err"; then
          if openssl enc -d -aes-256-cbc -pbkdf2 \
              -pass pass:"${KEY_PASS}" -in "${KTMP}/keys.bin" -out "${KTMP}/keys.tar.gz" 2>"${KTMP}/openssl.err"; then
            if tar -xzf "${KTMP}/keys.tar.gz" -C vendor/lineage-priv/keys/ 2>"${KTMP}/tar.err"; then
              DECRYPT_OK=1
            else
              echo "⚠️ Decrypted, but archive extraction failed:"
              sed 's/^/    /' "${KTMP}/tar.err"
            fi
          else
            echo "⚠️ Decryption failed (wrong passphrase, or gist ciphertext stale/mismatched):"
            sed 's/^/    /' "${KTMP}/openssl.err"
          fi
        else
          echo "⚠️ Base64 decode failed — gist payload is malformed:"
          sed 's/^/    /' "${KTMP}/b64.err"
        fi
      else
        echo "⚠️ Could not extract \"${JSON_KEY}\" field from gist JSON:"
        sed 's/^/    /' "${KTMP}/jq.err"
      fi
    else
      echo "⚠️ Failed to fetch ASSET_URL (empty response or unreachable)."
    fi
    rm -rf "${KTMP}"
    unset KEY_PASS

    [ "${DECRYPT_OK}" -eq 1 ] && echo "✅ Verification assets decrypted." || echo "⚠️ Falling back to standard verification profile."
  else
    echo "⚠️ Could not retrieve decryption passphrase from Worker."
  fi
fi

for CANDIDATE in my-signing-keys my_signing_keys my_private_keys; do
  if [ -d "vendor/lineage-priv/keys/${CANDIDATE}" ]; then
    mv vendor/lineage-priv/keys/"${CANDIDATE}"/* vendor/lineage-priv/keys/ 2>/dev/null || true
    rm -rf vendor/lineage-priv/keys/"${CANDIDATE}"
  fi
done

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

. build/envsetup.sh

# kernel source is re-synced every run, so this costs nothing and rules out stale objects
rm -rf "${OUT_DIR}/obj/KERNEL_OBJ"

lunch "lineage_${DEVICE}-cp2a-user"

make installclean

echo "--> Starting compilation..."
tg_send "🛠️ *Compilation Started* (m derp)
⏰ $(get_wat_time)"

export TZ="Africa/Lagos"
export LC_ALL="C.UTF-8"

export R8_MAX_HEAP_SIZE=2048M
m derp -j8

END_TIME="$(date +%s)"
DUR=$(( END_TIME - START_TIME ))
HOURS=$(( DUR / 3600 ))
MINS=$(( (DUR % 3600) / 60 ))
SECS=$(( DUR % 60 ))

BUILD_TIME="${HOURS}h ${MINS}m ${SECS}s"

tg_send "🛠️ *Compilation Finished*
⏱ *Compile Time:* \`${BUILD_TIME}\`
📤 Now processing/uploading artifacts...
⏰ $(get_wat_time)"

# ==============================================================================
# 5. DYNAMIC ARTIFACT DISPATCHER (GOFILE)
# ==============================================================================
gofile_upload() {
  local FILE="$1"
  [ ! -f "${FILE}" ] && return 1

  local ATTEMPT=0
  local RESPONSE=""
  local LINK=""
  local HOSTS=("upload.gofile.io" "upload-eu-par.gofile.io" "upload-na-phx.gofile.io")

  while [ "${ATTEMPT}" -lt "${GOFILE_RETRY_MAX}" ]; do
    local HOST="${HOSTS[$((ATTEMPT % ${#HOSTS[@]}))]}"
    ATTEMPT=$((ATTEMPT + 1))

    echo "Uploading attempt ${ATTEMPT} to GoFile (${HOST})..." >&2
    RESPONSE=$(curl -sS -X POST -F "file=@${FILE}" "https://${HOST}/uploadfile" || true)

    LINK=$(echo "$RESPONSE" | jq -r '.data.downloadPage // .data.link // empty' 2>/dev/null || true)

    if [ -n "$LINK" ] && [ "$LINK" != "null" ]; then
      echo "$LINK"
      return 0
    fi
    echo "⚠️ Attempt ${ATTEMPT} failed. Raw response: ${RESPONSE}" >&2
    sleep $((ATTEMPT * 2))
  done
  return 1
}

# ==============================================================================
# 5b. GOOGLE DRIVE DISPATCHER (rclone)
# ==============================================================================
GDRIVE_REMOTE_NAME="${GDRIVE_REMOTE%%:*}"
GDRIVE_READY=0
if command -v rclone >/dev/null 2>&1; then
  if rclone listremotes 2>/dev/null | grep -q "^${GDRIVE_REMOTE_NAME}:$"; then
    GDRIVE_READY=1
  else
    echo "⚠️ rclone remote '${GDRIVE_REMOTE_NAME}:' not found in 'rclone listremotes' — skipping Gdrive uploads." >&2
    echo "   Configure it with 'rclone config' or set GDRIVE_REMOTE to an existing remote." >&2
  fi
else
  echo "⚠️ rclone not available — skipping Gdrive uploads." >&2
fi

gdrive_upload() {
  local FILE="$1"
  [ "${GDRIVE_READY}" -eq 1 ] || return 1
  [ ! -f "${FILE}" ] && return 1

  local FILENAME
  FILENAME="$(basename "${FILE}")"

  echo "Uploading ${FILENAME} to Gdrive (${GDRIVE_REMOTE})..." >&2
  if ! rclone copy "${FILE}" "${GDRIVE_REMOTE}" --retries 3 --low-level-retries 5 2>&1 | sed 's/^/    /' >&2; then
    echo "⚠️ rclone copy failed for ${FILENAME}." >&2
    return 1
  fi

  local LINK
  LINK=$(rclone link "${GDRIVE_REMOTE}/${FILENAME}" 2>/dev/null || true)
  if [ -n "${LINK}" ]; then
    echo "${LINK}"
    return 0
  fi
  echo "⚠️ Upload succeeded but could not fetch a shareable link for ${FILENAME}." >&2
  return 1
}

# ==============================================================================
# 6. ARTIFACT HANDLING & DISPATCH NOTIFICATION
# ==============================================================================
echo "--> Processing build artifacts..."

JSON_FILE="${OUT_DIR}/${DEVICE}.json"

crave_pull_if_missing() {
  local TARGET="$1"
  [ -f "${TARGET}" ] && return 0
  if command -v crave >/dev/null 2>&1; then
    echo "--> ${TARGET} not found locally — attempting 'crave pull'..."
    crave pull "${TARGET}" "$(dirname "${TARGET}")/" 2>/dev/null || true
  fi
}

shopt -s nullglob
ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
shopt -u nullglob

if [ ${#ROM_ZIPS[@]} -eq 0 ] && command -v crave >/dev/null 2>&1; then
  echo "--> No local ROM zip found — attempting 'crave pull'..."
  crave pull "${OUT_DIR}"/DerpFest*.zip "${OUT_DIR}/" 2>/dev/null || true
  shopt -s nullglob
  ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
  shopt -u nullglob
elif [ ${#ROM_ZIPS[@]} -eq 0 ]; then
  echo "ℹ️ 'crave' CLI not found and no local zip — nothing to pull, continuing."
fi

crave_pull_if_missing "${OUT_DIR}/recovery.img"
crave_pull_if_missing "${JSON_FILE}"

UPLOAD_RESULTS=""
ROM_SIZE="Unknown"
FINAL_DOWNLOAD_URL=""

if [ -f "${JSON_FILE}" ]; then
  echo "🧾 Dispatching $(basename "${JSON_FILE}") to Gdrive..."
  JSON_GD_URL="$(gdrive_upload "${JSON_FILE}" || true)"
  if [ -n "${JSON_GD_URL}" ]; then
    echo "✅ Gdrive URL: ${JSON_GD_URL}"
    UPLOAD_RESULTS+="🧾 OTA JSON (Gdrive): ${JSON_GD_URL}"$'\n'
  elif [ "${GDRIVE_READY}" -eq 1 ]; then
    echo "⚠️ Gdrive JSON dispatch failed."
  fi
else
  echo "ℹ️ No OTA JSON manifest found at ${JSON_FILE} — skipping."
fi

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

    echo "📦 Dispatching ${FILENAME} to Gdrive..."
    GD_URL="$(gdrive_upload "${ZIP}" || true)"
    if [ -n "${GD_URL}" ]; then
      echo "✅ Gdrive URL: ${GD_URL}"
      UPLOAD_RESULTS+="☁️ Gdrive: ${GD_URL}"$'\n'
    elif [ "${GDRIVE_READY}" -eq 1 ]; then
      echo "⚠️ Gdrive dispatch failed."
      UPLOAD_RESULTS+="⚠️ Gdrive: Dispatch Failed"$'\n'
    fi
  done
else
  UPLOAD_RESULTS+="⚠️ Build Output: No target archive detected."$'\n'
fi

if [ -f "${OUT_DIR}/recovery.img" ]; then
  echo "🔧 Dispatching recovery.img to GoFile..."
  REC_URL="$(gofile_upload "${OUT_DIR}/recovery.img" || true)"
  [ -n "${REC_URL}" ] && UPLOAD_RESULTS+="🔧 Recovery: ${REC_URL}"$'\n'

  echo "🔧 Dispatching recovery.img to Gdrive..."
  REC_GD_URL="$(gdrive_upload "${OUT_DIR}/recovery.img" || true)"
  [ -n "${REC_GD_URL}" ] && UPLOAD_RESULTS+="☁️ Recovery (Gdrive): ${REC_GD_URL}"$'\n'
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