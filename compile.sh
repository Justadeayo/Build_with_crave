#!/usr/bin/env bash

export TZ="Africa/Lagos"

# ==============================================================================
# DEPENDENCY CHECK
# ==============================================================================

for tool in curl jq openssl git bc flex bison rsync zip unzip; do
  command -v "$tool" >/dev/null 2>&1 || echo "⚠️ Warning: $tool is not installed"
done

if ! command -v repo >/dev/null 2>&1; then
  echo "⚠️ 'repo' not found on PATH — expected to be preinstalled in the Crave build image."
  echo "If this isn't Crave, install it manually before continuing."
  echo "But this Crave, you don't have a choice 😉"
fi


free -h || true



# ==============================================================================
# NOTIFICATION & CREDENTIAL SETUP
# ==============================================================================
if [ -f "$(pwd)/.secrets.env" ]; then
  source "$(pwd)/.secrets.env"
  echo "✅ Loaded Telegram credentials"
else
  echo "⚠️ Telegram credentials file not found — notifications will be disabled."
fi

tg_send() {
  local msg="$1"
  if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
    curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "parse_mode=Markdown" \
      --data-urlencode "text=${msg}" >/dev/null 2>&1 || true
  fi
}

# Build Defaults
export ROM_NAME="${ROM_NAME:-DerpFest}"
export DEVICE="${DEVICE:-violet}"
export BUILD_TYPE="${BUILD_TYPE:-user}"
WORKER_URL="https://crave-ok.justadeayo.workers.dev"
ASSET_URL="https://gist.githubusercontent.com/Justadeayo/e7b4654edad28c965d015664884d896d/raw/a236bccd21e7443cd8fbcb5b35d03e8fd2579129/keys.json"
JSON_KEY="violet"
PRIV_DIR="vendor/lineage-priv/keys"
KEY_FP_EXPECTED="6B:E0:C5:88:6C:C1:FD:B7:52:48:8A:4F:4A:B6:C3:C1:AA:A7:23:27:20:65:9A:2F:38:59:9B:2D:B4:5C:89:F6"

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
# SECURE ERROR TRAP
# ==============================================================================
cleanup() {
  local exit_code=$?

   G=out/soong/.intermediates/vendor/lineage/build/soong/generated_kernel_includes
  echo "--> Generated kernel header check:"
  echo "    msm_ipa.h:    $(find "$G" -name msm_ipa.h -size +0 2>/dev/null | head -1)"
  echo "    videodev2.h:  $(find "$G" -name videodev2.h -size +0 2>/dev/null | head -1)"
  echo "    header files: $(find "$G" -name '*.h' 2>/dev/null | wc -l)"
  echo "    gcc/clang not found in log: $(zcat out/verbose.log.gz 2>/dev/null | grep -c -E '(gcc|clang): (not found|error)' || true)"
  zcat out/verbose.log.gz 2>/dev/null | grep -m1 -A25 'Entering directory.*generated_kernel_includes/gen' | cut -c1-200 | head -40 || true
  
  if [ "$exit_code" -ne 0 ]; then
    echo "❌ Script aborted with exit code ${exit_code}."
    tg_send "🚨 *Build Failed!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17)
⚠️ *Exit Code:* \`${exit_code}\`
⏰ *Failed at:* $(get_wat_time)"
  fi
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
echo "--> Wiping local git changes across all repos (edits AND untracked files)..."
repo forall -j"${JOBS}" -c 'if [ -n "$(git status --porcelain 2>/dev/null)" ]; then git reset --hard HEAD && git clean -fdx; fi' 2>/dev/null || true




echo "--> Cleaning up workspace lockfiles, local manifest paths, and conflicting hooks..."
find .repo/ -name "*.lock" -delete 2>/dev/null || true
find .repo/projects -type d -name hooks -exec rm -rf {} + 2>/dev/null || true
find .repo/project-objects -type d -name hooks -exec rm -rf {} + 2>/dev/null || true




rm -rf prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9 \
       .repo/local_manifests 2>/dev/null || true




run_step "Initializing Repository" repo init -u "${REPO_MANIFEST_URL}" -b "${REPO_MANIFEST_BRANCH}" --git-lfs --depth=1




echo "--> Fetching local device manifests..."
git clone --depth=1 -b "${MANIFEST_LOCAL_BRANCH}" "${MANIFEST_LOCAL_REPO}" .repo/local_manifests || true




if [ -f /opt/crave/resync.sh ]; then
  echo "--> Resyncing Sources via Crave..."
  /opt/crave/resync.sh
else
  run_step "Syncing Sources" repo sync -c --force-sync --force-remove-dirty --no-tags --no-clone-bundle --prune -j"${JOBS}"
fi



rm -rf hardware/xiaomi/packages/DSPVolumeSynchronizer






# ==============================================================================
# DEVICE TREE INTEGRITY CHECK
# ==============================================================================
DEVICE_TREE_DIR="device/xiaomi/violet"

if [ ! -f "${DEVICE_TREE_DIR}/lineage_violet.mk" ]; then
    echo "--> Device tree missing or invalid. Cloning started.."
    rm -rf "${DEVICE_TREE_DIR}"
    git clone --depth=1 https://github.com/Justadeayo/device_xiaomi_violet -b 17 "${DEVICE_TREE_DIR}"
else
    echo "✅ Device tree check passed."
fi

# ==============================================================================
# DISPLAY CAF HAL INTEGRITY CHECK
# ==============================================================================
DISPLAY_HAL_DIR="hardware/qcom-caf/sm8150/display"

if ! grep -q "generated_kernel_headers" "${DISPLAY_HAL_DIR}/Android.bp" 2>/dev/null \
   || [ ! -f "${DISPLAY_HAL_DIR}/include/linux/videodev2.h" ]; then    echo "--> Display HAL missing or invalid. Cloning custom fork..."
    rm -rf "${DISPLAY_HAL_DIR}"
    git clone --depth=1 https://github.com/Justadeayo/android_hardware_qcom_display -b lineage-24.0-caf-sm8150 "${DISPLAY_HAL_DIR}"
else
    echo "✅ Display HAL check passed."
fi


# ==============================================================================
# RELEASE KEYS CHECK AND AUTHORISE
# ==============================================================================

key_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

own_keys_ok() {
  [ -f "${PRIV_DIR}/releasekey.pk8" ] \
    && [ "$(key_fingerprint "${PRIV_DIR}/releasekey.x509.pem")" = "${KEY_FP_EXPECTED}" ]
}

load_keys() {
  local pass tmp response tmp_resp http_code

  if [ -n "${KEY_PASS}" ]; then
    pass="${KEY_PASS}"
  else
    tmp_resp="$(mktemp)"
    http_code="$(curl -sSL -w "%{http_code}" -o "${tmp_resp}" --max-time 10 "${WORKER_URL}/get-key" 2>/dev/null)"
    response="$(cat "${tmp_resp}")"
    rm -f "${tmp_resp}"

    if [ "${http_code}" -ne 200 ]; then
      echo "⚠️ Worker request failed with HTTP status ${http_code}."
      return 1
    fi

    pass="$(echo "${response}" | jq -r '.key // .passphrase // .secret // .pass // empty' 2>/dev/null)"
    if [ -z "${pass}" ] || [ "${pass}" = "null" ]; then
      pass="$(echo "${response}" | tr -d '\r\n' | sed -e 's/^ *//' -e 's/ *$//')"
    fi
  fi

  if [ -z "${pass}" ]; then
    echo "⚠️ No key passphrase available (KEY_PASS unset and Worker returned nothing)."
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

KEY_SOURCE=""
echo "--> Checking release keys..."
if own_keys_ok; then
  KEY_SOURCE="on disk"
elif load_keys; then
  KEY_SOURCE="gist fallback"
fi

if [ -n "${KEY_SOURCE}" ]; then
  printf 'PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey\n' > "${PRIV_DIR}/keys.mk"
  echo "✅ Release key verified (${KEY_SOURCE}). Building personal release-signed."
  tg_send "🔑 *Signing:* personal release key (${KEY_SOURCE}, fingerprint verified)"
else
  rm -f "${PRIV_DIR}/keys.mk"
  echo "⚠️ No verified release key. Building with the test key."
  tg_send "⚠️ *Release key unavailable.* Building test-signed (not dirty-flash compatible with release builds)."
fi




# ==============================================================================
# 1b. CLANG GUARD (fixes "Unable to find libclang" in libbinder_ndk_bindgen)
# ==============================================================================
CLANG_PRJ="prebuilts/clang/host/linux-x86"
CLANG_TAG="refs/tags/android-17.0.0_r1"
CLANG_WHY=""
CLANG_FIXED_BY=""

clang_ok() {
  local dir="$1"
  CLANG_WHY=""
  if ! "${dir}/bin/clang" --version >/dev/null 2>&1; then
    CLANG_WHY="bin/clang missing or will not run"; return 1
  fi

  local so
  so="$(find -L "${dir}/lib" -maxdepth 1 -name 'libclang.so*' -size +1M 2>/dev/null | head -1)"
  if [ -z "${so}" ]; then
    CLANG_WHY="no real libclang.so in lib/"; return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    exec 9>&2; exec 2>/dev/null
    python3 -c "import ctypes,sys; ctypes.CDLL(sys.argv[1])" "${so}" >/dev/null 2>&1
    local load_rc=$?
    exec 2>&9 9>&-
    if [ "${load_rc}" -ne 0 ]; then
      CLANG_WHY="libclang.so present but will not load (corrupt/truncated)"; return 1
    fi
  elif ! (readelf -h "${so}" >/dev/null 2>&1 && nm -D "${so}" >/dev/null 2>&1); then
    CLANG_WHY="libclang.so present but fails ELF/symbol check (corrupt/truncated)"; return 1
  fi
  if ! ls "${dir}"/lib/clang/*/include/stdbool.h >/dev/null 2>&1; then
    CLANG_WHY="builtin headers missing in lib/clang"; return 1
  fi
  return 0
}





repair_clang() {
  local prj="$1" name="$2" tag="$3" dir="$4"

  echo "--> Repair 1/2: restoring ${name} from git objects already in the workspace..."
  git -C "${prj}" checkout HEAD -- "${name}" 2>&1 | tail -3 || true
  if clang_ok "${dir}"; then CLANG_FIXED_BY="1/2 (git restore)"; return 0; fi

  echo "--> Repair 2/2: downloading ${name} straight from Google..."
  rm -rf "${dir}"
  mkdir -p "${dir}"
  curl -fsSL --retry 3 -o clang-dl.tgz \
    "https://android.googlesource.com/platform/${prj}/+archive/${tag}/${name}.tar.gz" \
    && tar -xzf clang-dl.tgz -C "${dir}" || true
  rm -f clang-dl.tgz
  if clang_ok "${dir}"; then CLANG_FIXED_BY="2/2 (Google download)"; return 0; fi

  return 1
}






ensure_clang() {
  local prj="$1" name="$2" tag="$3" dir="${1}/${2}"

  if clang_ok "${dir}"; then
    echo "✅ ${name} is complete."
    return 0
  fi
  local why="${CLANG_WHY}"
  echo "⚠️ ${name} incomplete (${why}) - repairing before the build..."

  local diff_log
  diff_log=$(git -C "${prj}" status --short -- "${name}" 2>&1 | head -20 || true)
  diff_log="${diff_log:-(none - git sees no differences)}"
  echo "${diff_log}"

  tg_send "⚠️ *${name} incomplete* (${why}) - repairing before build
\`\`\`
${diff_log}
\`\`\`" || true

  if ! repair_clang "${prj}" "${name}" "${tag}" "${dir}"; then
    echo "❌ Could not repair ${name} (${CLANG_WHY}); build would fail, so stopping now."
    tg_send "❌ Could not repair ${name} (${CLANG_WHY}); build would fail." || true
    exit 1
  fi
  echo "✅ ${name} repaired by repair ${CLANG_FIXED_BY}."
  tg_send "✅ ${name} repaired by repair ${CLANG_FIXED_BY}." || true
}




ensure_clang "${CLANG_PRJ}" "clang-r584948" "${CLANG_TAG}"
ensure_clang "${CLANG_PRJ}" "clang-r596125" "${CLANG_TAG}"





CROSS_TOOLS="arm-linux-gnueabi-gcc arm-linux-gnueabi-ld aarch64-linux-gnu-gcc aarch64-linux-gnu-ld aarch64-linux-gnu-elfedit"
missing_tools() {
  local t out=""
  for t in ${CROSS_TOOLS}; do
    command -v "${t}" >/dev/null 2>&1 || out="${out} ${t}"
  done
  echo "${out# }"
}
if [ -n "$(missing_tools)" ]; then
  echo "⚠️ Missing cross tools: $(missing_tools) — attempting install..."
  sudo apt-get update -qq && sudo apt-get install -y gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu || true
  if [ -z "$(missing_tools)" ]; then
    echo "✅ Cross toolchains ready."
  else
    echo "⚠️ Still missing: $(missing_tools) — the inline kernel build will fail."
  fi
fi




K=kernel/xiaomi/violet
H=$(git -C $K rev-parse HEAD)
if [ "$(cat .kernel_headers_rev 2>/dev/null)" != "$H" ]; then
  rm -rf out/soong/.intermediates/vendor/lineage/build/soong/generated_kernel_includes
  rm -rf "${OUT_DIR}/obj/KERNEL_OBJ"
  echo "$H" > .kernel_headers_rev
fi







# ==============================================================================
# 3. BUILD COMPILATION (FORCE WAT TIMESTAMPS & CP2A TARGET)
# ==============================================================================
echo "--> Setting up build environment..."

. build/envsetup.sh

lunch "lineage_${DEVICE}-cp2a-user"

make installclean

echo "--> Starting compilation..."

export TZ="Africa/Lagos"
export LC_ALL="C.UTF-8"
export R8_MAX_HEAP_SIZE=4096M
export BUILD_BROKEN_MISSING_REQUIRED_MODULES=true
export NINJA_ARGS="-k 0"


tg_send "🛠️ *Compilation Started* (m derp)
⏰ $(get_wat_time)"

BUILD_OK=0
if m derp; then
  BUILD_OK=1
fi

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


BUILD_TIME="${BUILD_TIME:-unknown}"

# ==============================================================================
# DISPATCH: GOFILE (ROM + recovery) AND TELEGRAM (JSON)
# ==============================================================================
gofile_upload() {
  local FILE="$1"
  [ ! -f "${FILE}" ] && return 1

  local ATTEMPT=0 RESPONSE="" LINK=""
  local HOSTS=("upload.gofile.io" "upload-eu-par.gofile.io" "upload-na-phx.gofile.io")

  while [ "${ATTEMPT}" -lt 8 ]; do
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

tg_send_file() {
  local FILE="$1" CAPTION="$2"
  [ ! -f "${FILE}" ] && { echo "⚠️ Not found: ${FILE}"; return 1; }
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] && return 1
  local SIZE
  SIZE=$(stat -c %s "${FILE}")
  if [ "${SIZE}" -gt 52428800 ]; then
    tg_send "⚠️ \`$(basename "${FILE}")\` is over 50 MB, not sent to Telegram."
    return 1
  fi
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "caption=${CAPTION}" \
    -F "document=@${FILE}" >/dev/null 2>&1 || true
}

BUILD_OK="${BUILD_OK:-0}"
ROM_ZIP=$(ls -t "${OUT_DIR}"/DerpFest-*.zip 2>/dev/null | head -1 || true)
RECOVERY_LINK=""
UPLOAD_RESULTS=""

if [ "${BUILD_OK}" -ne 1 ]; then
  ROM_SIZE="not built"
  UPLOAD_RESULTS="❌ Build failed. Nothing uploaded."
elif [ -n "${ROM_ZIP}" ] && [ -f "${ROM_ZIP}" ]; then
  ROM_SIZE=$(du -h "${ROM_ZIP}" | cut -f1)
  ROM_SHA=$(sha256sum "${ROM_ZIP}" | cut -d' ' -f1)
  ROM_LINK=$(gofile_upload "${ROM_ZIP}" || true)
  UPLOAD_RESULTS="📤 *GoFile (ROM):* ${ROM_LINK:-upload failed}
🔐 *SHA256:* \`${ROM_SHA}\`"
  tg_send_file "${OUT_DIR}/${DEVICE}.json" "OTA json"
  RECOVERY_LINK=$(gofile_upload "${OUT_DIR}/recovery.img" || true)
else
  ROM_SIZE="not found"
  UPLOAD_RESULTS="❌ ROM zip not found in ${OUT_DIR}"
fi

tg_send "🎉 *Build Finished!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17)
⏱ *Compile Time:* \`${BUILD_TIME}\`
📏 *Size:* \`${ROM_SIZE}\`
⏰ *Finished at:* $(get_wat_time)

${UPLOAD_RESULTS}
🧰 *Recovery (GoFile):* ${RECOVERY_LINK:-not uploaded}"