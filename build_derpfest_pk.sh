#!/usr/bin/env bash

set -e
export TZ="Africa/Lagos"

# ==============================================================================
# 0. FETCH DEPENDENCIES — one curl per file, sourced in order
# ==============================================================================
RAW_BASE="https://raw.githubusercontent.com/Justadeayo/Build_with_crave/refs/heads/main"
LIB_DIR="/tmp/build-libs"
mkdir -p "${LIB_DIR}"

fetch_lib() {
  local name="$1" dest="${LIB_DIR}/$1"
  if ! curl -fsSL -o "${dest}" "${RAW_BASE}/${name}"; then
    echo "❌ Could not download ${name} — aborting." >&2
    exit 1
  fi
  [ -s "${dest}" ] || { echo "❌ ${name} downloaded empty — aborting." >&2; exit 1; }
  source "${dest}"
}

fetch_lib "deps.sh"
fetch_lib "notify.sh"
fetch_lib "clang_repair.sh"
fetch_lib "keys.sh"
fetch_lib "upload.sh"

check_and_install_deps curl jq openssl git rclone
command -v repo >/dev/null 2>&1 || echo "⚠️ 'repo' not found on PATH — expected preinstalled in the Crave image."




# ==============================================================================
# CONFIG
# ==============================================================================
export ROM_NAME="${ROM_NAME:-DerpFest}"
export DEVICE="${DEVICE:-violet}"
export BUILD_TYPE="${BUILD_TYPE:-user}"
export BUILD_USERNAME="${BUILD_USERNAME:-Justus26}"
export BUILD_HOSTNAME="${BUILD_HOSTNAME:-crave}"

REPO_MANIFEST_URL="https://github.com/DerpFest-AOSP/android_manifest"
REPO_MANIFEST_BRANCH="17"
MANIFEST_LOCAL_REPO="https://github.com/Justadeayo/Manifest.git"
MANIFEST_LOCAL_BRANCH="17p"

OUT_DIR="out/target/product/${DEVICE}"
GOFILE_RETRY_MAX=8
GDRIVE_REMOTE="${GDRIVE_REMOTE:-${DEVICE}:DerpFest_Builds}"
JOBS=$(nproc 2>/dev/null || echo 4)
SM="Default"
START_TIME="$(date +%s)"

trap cleanup EXIT INT TERM
upload_init

banner "${ROM_NAME}" "${DEVICE}" "${REPO_MANIFEST_BRANCH} (prebuilt kernel)"
tg_send "🚀 *Build Started!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17, prebuilt kernel)
⏰ *Started at:* $(get_wat_time)"




# ==============================================================================
# 1. CLEANUP & SOURCE SYNC
# ==============================================================================
section "cleaning workspace + syncing sources"

repo forall -j"${JOBS}" -c 'if [ -n "$(git status --porcelain 2>/dev/null)" ]; then git reset --hard HEAD && git clean -fdx; fi' 2>/dev/null || true
find .repo/ -name "*.lock" -delete 2>/dev/null || true
find .repo/projects -type d -name hooks -exec rm -rf {} + 2>/dev/null || true

rm -rf vendor/MiuiCamera \
       device/xiaomi/violet \
       kernel/xiaomi/violet \
       vendor/xiaomi/violet \
       hardware/xiaomi \
       hardware/dolby \
       .repo/local_manifests 2>/dev/null || true

run_step "Initializing Repository" repo init -u "${REPO_MANIFEST_URL}" -b "${REPO_MANIFEST_BRANCH}" --git-lfs --depth=1
git clone --depth=1 -b "${MANIFEST_LOCAL_BRANCH}" "${MANIFEST_LOCAL_REPO}" .repo/local_manifests || true

if [ -f /opt/crave/resync.sh ]; then
  run_step "Syncing with Crave✅" /opt/crave/resync.sh
else
  run_step "Syncing Sources" repo sync -c --force-sync --force-remove-dirty --no-tags --no-clone-bundle --prune -j"${JOBS}"
fi




# ==============================================================================
# 2. TOOLCHAIN GUARD + HARDWARE TREES
# ==============================================================================
section "verifying toolchain + hardware trees"

setup_host_clang

rm -rf hardware/xiaomi
run_step "Cloning Xiaomi Hardware" git clone https://github.com/Evolution-X-Devices/hardware_xiaomi -b bka-no-dolby hardware/xiaomi
rm -rf hardware/xiaomi/packages/DSPVolumeSynchronizer

rm -rf hardware/dolby
run_step "Cloning Dolby Hardware" git clone https://github.com/adi8900/hardware_dolby -b lunaris hardware/dolby
echo "✅ Hardware paths configured!"

echo "--> Using prebuilt kernel - skipping kernel clang setup."




# ==============================================================================
# 3. SIGNING ASSETS
# ==============================================================================
section "verifying signing assets"
setup_signing_keys





# ==============================================================================
# 4. BUILD
# ==============================================================================
section "starting build"

. build/envsetup.sh
rm -rf "${OUT_DIR}/obj/KERNEL_OBJ"
lunch "lineage_${DEVICE}-cp2a-user"
make installclean

tg_send "🛠️ *Compilation Started* (m derp)
⏰ $(get_wat_time)"

export TZ="Africa/Lagos"
export LC_ALL="C.UTF-8"
export R8_MAX_HEAP_SIZE=2048M
export BUILD_BROKEN_MISSING_REQUIRED_MODULES=true

m derp

END_TIME="$(date +%s)"
DUR=$(( END_TIME - START_TIME ))
BUILD_TIME="$(( DUR / 3600 ))h $(( (DUR % 3600) / 60 ))m $(( DUR % 60 ))s"

tg_send "🛠️ *Compilation Finished*
⏱ *Compile Time:* \`${BUILD_TIME}\`
📤 Now processing/uploading artifacts...
⏰ $(get_wat_time)"




# ==============================================================================
# 5. ARTIFACT DISPATCH
# ==============================================================================
section "uploading to sharing platforms"
dispatch_artifacts

tg_send "🎉 *Build Finished Successfully!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17, prebuilt kernel)
🔑 *Profile Mode:* \`${SM}\` (${KEY_COUNT:-0} keys)
⏱ *Compilation Time:* \`${BUILD_TIME}\`
📏 *Size:* \`${ROM_SIZE}\`
⏰ *Finished at:* $(get_wat_time)

${UPLOAD_RESULTS}"

section "process finished successfully 🎉"