#!/usr/bin/env bash
set -e
export TZ="Africa/Lagos"

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT & NOTIFICATIONS
# ------------------------------------------------------------------------------
DEVICE="violet"
OUT_DIR="out/target/product/${DEVICE}"
WORKER_URL="https://crave-ok.justadeayo.workers.dev"

tg_send() {
  curl -sS -X POST "${WORKER_URL}" --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

tg_send "🚀 *Build Started:* ${DEVICE} (DerpFest A17)"

# ------------------------------------------------------------------------------
# 2. LOCAL MANIFESTS & CRAVE RESYNC
# ------------------------------------------------------------------------------
# rm -rf prebuilts/clang/host/linux-x86/clang-r584948
repo init -u https://github.com/DerpFest-AOSP/android_manifest -b 17 --git-lfs --depth=1
rm -rf .repo/local_manifests
git clone --depth=1 -b main https://github.com/Justadeayo/Manifest.git .repo/local_manifests

if [ -f /opt/crave/resync.sh ]; then
  echo "--> Executing Crave resync..."
  /opt/crave/resync.sh
fi

rm -rf kernel/xiaomi/violet

# ------------------------------------------------------------------------------
# 3. HARDWARE TREES
# ------------------------------------------------------------------------------
rm -rf hardware/xiaomi hardware/dolby
git clone --depth=1 https://github.com/Evolution-X-Devices/hardware_xiaomi -b bka-no-dolby hardware/xiaomi
rm -rf hardware/xiaomi/packages/DSPVolumeSynchronizer
git clone --depth=1 https://github.com/adi8900/hardware_dolby -b lunaris hardware/dolby

# ------------------------------------------------------------------------------
# 4. SIGNING REGISTER
# ------------------------------------------------------------------------------
mkdir -p vendor/lineage-priv/keys
KEY_PASS=$(curl -sSL "${WORKER_URL}/get-key" | tr -d '\r\n')

if [ -n "${KEY_PASS}" ]; then
  KTMP=$(mktemp -d)
  if curl -sSL "https://gist.githubusercontent.com/Justadeayo/9f813a5fd4b35290aa666fac735fda4d/raw/32ac18aae99a1712e804d31ac0a02b767d915163/keys.json" -o "${KTMP}/keys.json"; then
    jq -r '.["my-signing-keys"] // empty' "${KTMP}/keys.json" | base64 -d | openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"${KEY_PASS}" | tar -xz -C vendor/lineage-priv/keys/ 2>/dev/null || true
  fi
  rm -rf "${KTMP}"
fi

# Normalize key paths if extracted into a nested directory
for dir in my-signing-keys my_signing_keys; do
  if [ -d "vendor/lineage-priv/keys/${dir}" ]; then
    mv vendor/lineage-priv/keys/${dir}/* vendor/lineage-priv/keys/ 2>/dev/null || true
    rm -rf "vendor/lineage-priv/keys/${dir}"
  fi
done

if [ -f vendor/lineage-priv/keys/releasekey.pk8 ]; then
  export PRODUCT_DEFAULT_DEV_CERTIFICATE=vendor/lineage-priv/keys/releasekey
  echo "✅ Custom release keys applied."
  tg_send "Signing Keys Loaded"
fi

# ------------------------------------------------------------------------------
# 5. BUILD EXECUTION
# ------------------------------------------------------------------------------
. build/envsetup.sh
lunch "lineage_${DEVICE}-cp2a-user"
make installclean

export LC_ALL="C.UTF-8"
export R8_MAX_HEAP_SIZE=2048M

tg_send "🛠️ *Compilation Started:* m derp"
m derp

# ------------------------------------------------------------------------------
# 6. ARTIFACT HANDLING & DISPATCH
# ------------------------------------------------------------------------------
shopt -s nullglob
ZIP=( "${OUT_DIR}"/DerpFest*.zip )
shopt -u nullglob

if [ ${#ZIP[@]} -gt 0 ]; then
  URL=$(curl -sS -X POST -F "file=@${ZIP[0]}" https://upload.gofile.io/uploadfile | jq -r '.data.downloadPage // .data.link // empty')
  tg_send "🎉 *Build Succeeded!*
📦 Download: ${URL:-Failed to acquire GoFile URL}"
else
  tg_send "❌ *Build Completed*, but no output zip found in ${OUT_DIR}."
fi

# Clean keys from disk after build completion
rm -rf vendor/lineage-priv/keys/*.pk8 vendor/lineage-priv/keys/*.x509.pem 2>/dev/null || true