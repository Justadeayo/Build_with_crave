#!/usr/bin/env bash
# DerpFest (Android 17) on Crave: sync -> keys -> build -> one Telegram message
set -e
export TZ="Africa/Lagos"

# ---- config -------------------------------------------------------------------
export ROM_NAME="${ROM_NAME:-DerpFest}"
export DEVICE="${DEVICE:-violet}"
export BUILD_TYPE="${BUILD_TYPE:-user}"
export BUILD_USERNAME="${BUILD_USERNAME:-Justus26}"
export BUILD_HOSTNAME="${BUILD_HOSTNAME:-crave}"
export CCACHE="0"

WORKER_URL="https://crave-ok.justadeayo.workers.dev"   # Telegram relay + /get-key passphrase
ASSET_URL="https://gist.githubusercontent.com/Justadeayo/9f813a5fd4b35290aa666fac735fda4d/raw/32ac18aae99a1712e804d31ac0a02b767d915163/keys.json"
JSON_KEY="my-signing-keys"
KEYS_DIR="vendor/lineage-priv/keys"
PRODUCT_OUT="out/target/product/${DEVICE}"

START=$(date +%s)
STAGE="start"
KEY_MODE="default"

# ---- helpers ------------------------------------------------------------------
stage() { STAGE="$1"; echo "--> $1"; }
tg()    { curl -sS -X POST "${WORKER_URL}" --data-urlencode "text=$1" >/dev/null 2>&1 || true; }

# One message at the end (done or failed) + always wipe the signing keys.
finish() {
  local rc=$? mins zip info
  trap - EXIT
  mins=$(( ($(date +%s) - START) / 60 ))
  rm -rf "${KEYS_DIR}"/*.pk8 "${KEYS_DIR}"/*.x509.pem 2>/dev/null || true
  if [ "${rc}" -eq 0 ]; then
    zip="$(ls -1 "${PRODUCT_OUT}"/DerpFest*.zip 2>/dev/null | head -1 || true)"
    if [ -n "${zip}" ]; then info="$(basename "${zip}") ($(du -h "${zip}" | cut -f1))"; else info="no zip found"; fi
    tg "✅ ${ROM_NAME} · ${DEVICE} built in ${mins}m
🔑 keys: ${KEY_MODE}
📦 ${info}"
  else
    tg "❌ ${ROM_NAME} · ${DEVICE} failed at '${STAGE}' (exit ${rc}) after ${mins}m"
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Decrypt the signing keys from the gist into KEYS_DIR. Returns 1 on any problem.
load_keys() {
  local pass tmp
  pass="$(curl -sSL "${WORKER_URL}/get-key" 2>/dev/null | tr -d '\r\n' | sed -e 's/^ *//' -e 's/ *$//')"
  [ -n "${pass}" ] || { echo "⚠️ no passphrase from Worker"; return 1; }

  tmp="$(mktemp)"
  curl -fsSL "${ASSET_URL}" 2>/dev/null | jq -er --arg k "${JSON_KEY}" '.[$k] // empty' 2>/dev/null | base64 -d > "${tmp}" 2>/dev/null || true
  [ -s "${tmp}" ] || { rm -f "${tmp}"; echo "⚠️ could not fetch '${JSON_KEY}' from keys.json"; return 1; }

  KEY_PASS="${pass}" openssl enc -d -aes-256-cbc -pbkdf2 -pass env:KEY_PASS -in "${tmp}" 2>/dev/null \
    | tar -xzC "${KEYS_DIR}" 2>/dev/null \
    || { rm -f "${tmp}"; echo "⚠️ decrypt/extract failed (wrong passphrase or stale gist)"; return 1; }
  rm -f "${tmp}"

  # tarball may hold a sub-folder: flatten it
  find "${KEYS_DIR}" -mindepth 2 -type f -exec mv -t "${KEYS_DIR}" {} + 2>/dev/null || true
  find "${KEYS_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  [ -f "${KEYS_DIR}/releasekey.pk8" ]
}

# ---- 1. sync ------------------------------------------------------------------
stage "sync"
repo forall -c 'git diff-index --quiet HEAD -- || (git reset --hard HEAD && git clean -fdx)' >/dev/null 2>&1 || true
find .repo/ -name "*.lock" -delete 2>/dev/null || true
rm -rf vendor/MiuiCamera hardware/xiaomi hardware/dolby "${KEYS_DIR}" .repo/local_manifests

repo init -u https://github.com/DerpFest-AOSP/android_manifest -b 17 --git-lfs --depth=1
git clone --depth=1 -b main https://github.com/Justadeayo/Manifest.git .repo/local_manifests

if [ -f /opt/crave/resync.sh ]; then
  /opt/crave/resync.sh
else
  repo sync -c --force-sync --no-tags --no-clone-bundle --prune -j"$(nproc)"
fi

# violet trees: always fresh
rm -rf kernel/xiaomi/violet device/xiaomi/violet vendor/xiaomi/violet
repo sync --force-sync --no-tags --no-clone-bundle -j"$(nproc)" \
  kernel/xiaomi/violet device/xiaomi/violet vendor/xiaomi/violet

# ---- 2. custom hardware -------------------------------------------------------
stage "hardware"
rm -rf hardware/xiaomi hardware/dolby      # the sync above can bring these back
git clone -q https://github.com/Evolution-X-Devices/hardware_xiaomi -b bka-no-dolby hardware/xiaomi
rm -rf hardware/xiaomi/packages/DSPVolumeSynchronizer
git clone -q https://github.com/adi8900/hardware_dolby -b lunaris hardware/dolby

# ---- 3. signing keys (fall back to default keys if anything goes wrong) -------
stage "keys"
mkdir -p "${KEYS_DIR}"
if load_keys; then
  export PRODUCT_DEFAULT_DEV_CERTIFICATE="${KEYS_DIR}/releasekey"
  KEY_MODE="custom"
else
  rm -rf "${KEYS_DIR:?}"/*
  echo "⚠️ building with default keys"
fi

# ---- 4. build -----------------------------------------------------------------
stage "build"
. build/envsetup.sh
rm -rf "${PRODUCT_OUT}/obj/KERNEL_OBJ"
lunch "lineage_${DEVICE}-cp2a-${BUILD_TYPE}"
make installclean

export LC_ALL="C.UTF-8"
export R8_MAX_HEAP_SIZE=2048M
m derp -j8

echo "✅ Done: $(ls -1 "${PRODUCT_OUT}"/DerpFest*.zip 2>/dev/null | head -1)"
