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

check_and_install_deps curl jq openssl git bc flex bison rsync zip unzip ssh

free -h || true

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
MANIFEST_LOCAL_BRANCH="main"

OUT_DIR="out/target/product/${DEVICE}"
JOBS=$(nproc 2>/dev/null || echo 4)
SM="Default"
START_TIME="$(date +%s)"

trap cleanup EXIT INT TERM

banner "${ROM_NAME}" "${DEVICE}" "${REPO_MANIFEST_BRANCH} (full kernel)"

tg_send "🚀 *Build Started!*

📱 *Device:* \`${DEVICE}\`

📦 *ROM:* \`${ROM_NAME}\` (Android 17)

⏰ *Started at:* $(get_wat_time)"

# ==============================================================================
# 1. CLEANUP & SOURCE SYNC
# ==============================================================================
section "cleaning workspace + syncing sources"

echo "--> Wiping local git changes across all repos (edits AND untracked files)..."
repo forall -j"${JOBS}" -c 'if [ -n "$(git status --porcelain 2>/dev/null)" ]; then git reset --hard HEAD && git clean -fdx; fi' 2>/dev/null || true

echo "--> Cleaning up workspace lockfiles, local manifest paths, and conflicting hooks..."
find .repo/ -name "*.lock" -delete 2>/dev/null || true
find .repo/projects -type d -name hooks -exec rm -rf {} + 2>/dev/null || true
find .repo/project-objects -type d -name hooks -exec rm -rf {} + 2>/dev/null || true

rm -rf prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9 \
       .repo/local_manifests 2>/dev/null

run_step "Initializing Repository" repo init -u "${REPO_MANIFEST_URL}" -b "${REPO_MANIFEST_BRANCH}" --git-lfs --depth=1

echo "--> Fetching local device manifests..."
git clone --depth=1 -b "${MANIFEST_LOCAL_BRANCH}" "${MANIFEST_LOCAL_REPO}" .repo/local_manifests

if [ -f /opt/crave/resync.sh ]; then
  echo "--> Resyncing Sources via Crave..."
  /opt/crave/resync.sh
else
  run_step "Syncing Sources" repo sync -c --force-sync --force-remove-dirty --no-tags --no-clone-bundle --prune -j"${JOBS}"
fi

# ==============================================================================
# 2. TOOLCHAIN GUARDS + HARDWARE TREES
# ==============================================================================
section "verifying toolchains + hardware trees"

ensure_clang "${CLANG_PRJ}" "clang-r584948" "${CLANG_TAG}"
ensure_clang "${CLANG_PRJ}" "clang-r596125" "${CLANG_TAG}"

ensure_cross_tools


# ==============================================================================
# 3. SIGNING ASSETS
# ==============================================================================
section "verifying signing assets"

setup_signing_keys

# ==============================================================================
# 4. BUILD
# ==============================================================================
section "starting build"

echo "--> Setting up build environment..."
. build/envsetup.sh

lunch "lineage_${DEVICE}-cp2a-user"

make installclean

echo "--> Starting compilation..."

export TZ="Africa/Lagos"
export LC_ALL="C.UTF-8"
export R8_MAX_HEAP_SIZE=8192M
export NINJA_ARGS="-k 0"

tg_send "🛠️ *Compilation Started, grab some coffee and hope for the best*
⏰ $(get_wat_time)"

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

📦 *ROM:* \`${ROM_NAME}\` (Android 17)

🔑 *Profile Mode:* \`${SM}\` (${KEY_COUNT:-0} keys)

⏱ *Compilation Time:* \`${BUILD_TIME}\`

📏 *Size:* \`${ROM_SIZE}\`

⏰ *Finished at:* $(get_wat_time)

${UPLOAD_RESULTS}"

section "process finished successfully 🎉"
