#!/usr/bin/env bash
set -e
export TZ="Africa/Lagos"

DEVICE="violet"
JOBS=$(nproc 2>/dev/null || echo 4)
OUT_DIR="out/target/product/${DEVICE}"
WORKER_URL="https://crave-ok.justadeayo.workers.dev"

tg_send() { curl -sS -X POST "${WORKER_URL}" --data-urlencode "text=$1" >/dev/null 2>&1 || true; }

repo init -u https://github.com/DerpFest-AOSP/android_manifest -b 17 --git-lfs --depth=1
rm -rf .repo/local_manifests
git clone --depth=1 -b main https://github.com/Justadeayo/Manifest.git .repo/local_manifests
repo sync -c --force-sync --no-tags --no-clone-bundle -j"${JOBS}"

mkdir -p vendor/lineage-priv/keys
KEY_PASS=$(curl -sSL "${WORKER_URL}/get-key" | tr -d '\r\n')
curl -sSL "https://gist.githubusercontent.com/Justadeayo/9f813a5fd4b35290aa666fac735fda4d/raw/32ac18aae99a1712e804d31ac0a02b767d915163/keys.json" -o keys.json
jq -r '.["my-signing-keys"]' keys.json | base64 -d | openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"${KEY_PASS}" | tar -xz -C vendor/lineage-priv/keys/
[ -f vendor/lineage-priv/keys/releasekey.pk8 ] && export PRODUCT_DEFAULT_DEV_CERTIFICATE=vendor/lineage-priv/keys/releasekey
rm -f keys.json; unset KEY_PASS

source build/envsetup.sh
lunch "lineage_${DEVICE}-cp2a-user"
tg_send "🛠️ Build started: ${DEVICE}"
m derp -j"${JOBS}"

ZIP=$(ls "${OUT_DIR}"/DerpFest*.zip 2>/dev/null | head -1)
if [ -n "${ZIP}" ]; then
  URL=$(curl -sS -X POST -F "file=@${ZIP}" https://upload.gofile.io/uploadfile | jq -r '.data.downloadPage // empty')
  tg_send "🎉 Build finished: ${DEVICE}
📦 ${URL:-upload failed, check workspace}"
else
  tg_send "❌ Build finished but no zip found for ${DEVICE}"
fi