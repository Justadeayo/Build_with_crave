#!/usr/bin/env bash
#
# compile-test.sh — Termux dry-run harness for compile.sh
#
# WHAT THIS DOES vs THE REAL SCRIPT:
#   REAL (unchanged, actually executed):
#     - tg_send()      -> hits your real WORKER_URL, real Telegram message
#     - run_step()     -> real wrapper: start/success/fail notifications, real exit-on-failure
#     - cleanup()/trap -> real EXIT/INT/TERM handling
#     - key decrypt    -> real curl to WORKER_URL/get-key + real gist fetch (tiny payload)
#     - gofile_upload() -> real upload to GoFile, real API response parsing
#   MOCKED (AOSP-specific, cannot run without host toolchain + huge source tree):
#     - repo init / repo sync / crave resync  -> replaced with mkdir + sleep (proves control flow only)
#     - hardware tree git clones               -> replaced with mkdir + sleep
#     - `. build/envsetup.sh`, lunch, `m derp`  -> replaced with a small dummy "build artifact"
#       generated via dd, sized ~5-15MB, matching the same filename glob the real script looks for
#
# Run with: bash compile-test.sh
# Needs: bash, curl, jq, openssl, git  (all present in Termux via `pkg install`)

set -e
export TZ="Africa/Lagos"

check_and_install_deps() {
  local missing=()
  for dep in "$@"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  echo "⚠️ Missing dependencies: ${missing[*]} — attempting install..."

  if command -v pkg >/dev/null 2>&1; then
    # Termux
    pkg install -y "${missing[@]}" || true
  elif command -v apt-get >/dev/null 2>&1; then
    # Crave devspaces / Debian-based container
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update -qq && apt-get install -y "${missing[@]}" || true
    else
      sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}" || true
    fi
  else
    echo "❌ No known package manager (pkg/apt-get) found — install manually: ${missing[*]}"
    exit 1
  fi

  local still_missing=()
  for dep in "${missing[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || still_missing+=("$dep")
  done
  if [ "${#still_missing[@]}" -gt 0 ]; then
    echo "❌ Still missing after install attempt: ${still_missing[*]} — install manually and re-run."
    exit 1
  fi
  echo "✅ Installed: ${missing[*]}"
}

check_and_install_deps curl jq openssl rclone

# ==============================================================================
# NOTIFICATION & KEY RELAY CONFIGURATION (REAL — same as compile.sh)
# ==============================================================================
WORKER_URL="https://crave-ok.justadeayo.workers.dev"

tg_send() {
  local msg="$1"
  if [ -n "${WORKER_URL}" ]; then
    curl -sS -X POST "${WORKER_URL}" \
      --data-urlencode "text=${msg}" >/dev/null 2>&1 || true
  fi
}

export ROM_NAME="${ROM_NAME:-DerpFest}"
export DEVICE="${DEVICE:-violet}"
export BUILD_TYPE="${BUILD_TYPE:-user}"
export BUILD_USERNAME="${BUILD_USERNAME:-Justus26}"
export BUILD_HOSTNAME="${BUILD_HOSTNAME:-crave}"

OUT_DIR="test-out/target/product/${DEVICE}"
GOFILE_RETRY_MAX=3
GDRIVE_REMOTE="${GDRIVE_REMOTE:-${DEVICE}:DerpFest_Builds}"
JOBS=$(nproc 2>/dev/null || echo 4)
SM="Default"
START_TIME="$(date +%s)"

get_wat_time() {
  TZ="Africa/Lagos" date +'%Y-%m-%d %H:%M:%S WAT'
}

# ==============================================================================
# SECURE CLEANUP FUNCTION & ERROR TRAP (REAL — same as compile.sh)
# ==============================================================================
cleanup() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo "❌ Script aborted with exit code ${exit_code}."
    tg_send "🚨 *[TEST] Build Failed!*
📱 *Device:* \`${DEVICE}\`
⚠️ *Exit Code:* \`${exit_code}\`
⏰ *Failed at:* $(get_wat_time)"
  fi
  echo "🧹 Cleaning up test workspace..."
  rm -rf test-workspace test-out 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ==============================================================================
# STEP EXECUTION WRAPPER (REAL — same as compile.sh)
# ==============================================================================
run_step() {
  local step_name="$1"
  shift
  echo "--> Executing: ${step_name}..."
  tg_send "▶️ *[TEST] ${step_name}*
⏰ $(get_wat_time)"
  if ! "$@"; then
    echo "❌ Step failed: ${step_name}"
    tg_send "❌ *[TEST] Step Failed:* ${step_name}
⏰ $(get_wat_time)"
    exit 1
  fi
  tg_send "✅ *[TEST] ${step_name}* — done
⏰ $(get_wat_time)"
}

echo "========================================="
echo " [TEST MODE] $ROM_NAME (Android 17) for $DEVICE "
echo "========================================="
tg_send "🚀 *[TEST] Build Started!*
📱 *Device:* \`${DEVICE}\`
⏰ *Started at:* $(get_wat_time)"

mkdir -p test-workspace && cd test-workspace

# ==============================================================================
# 1. MOCKED: repo init / sync / force-resync
#    (proves the control flow + rm-rf-then-resync pattern, no real repo/source)
# ==============================================================================
run_step "Initializing Repository" bash -c 'mkdir -p .repo && sleep 1'

run_step "Syncing Sources" bash -c 'sleep 1 && mkdir -p kernel/xiaomi/violet device/xiaomi/violet vendor/xiaomi/violet && touch kernel/xiaomi/violet/OLD_MARKER'

echo "--> Force-refreshing pinned local-manifest projects (mocked)..."
rm -rf kernel/xiaomi/violet device/xiaomi/violet vendor/xiaomi/violet
run_step "Force Re-sync (pinned projects)" bash -c 'sleep 1 && mkdir -p kernel/xiaomi/violet device/xiaomi/violet vendor/xiaomi/violet && touch kernel/xiaomi/violet/FRESH_MARKER'

if [ -f kernel/xiaomi/violet/FRESH_MARKER ] && [ ! -f kernel/xiaomi/violet/OLD_MARKER ]; then
  echo "✅ Force re-sync logic confirmed: stale marker gone, fresh marker present."
else
  echo "❌ Force re-sync logic FAILED — stale state survived."
  exit 1
fi

# ==============================================================================
# 2. MOCKED: hardware tree clones
# ==============================================================================
run_step "Cloning Xiaomi Hardware" bash -c 'sleep 1 && mkdir -p hardware/xiaomi'
run_step "Cloning Dolby Hardware" bash -c 'sleep 1 && mkdir -p hardware/dolby'

# ==============================================================================
# 3. REAL: key relay check (tiny payload, exercises actual WORKER_URL + gist)
# ==============================================================================
mkdir -p vendor/lineage-priv/keys
ASSET_URL="${ASSET_URL:-https://gist.githubusercontent.com/Justadeayo/6742bf0ae5ee32d09c9326a22aed1018/raw/6899053ffae911028507e978e3d8e97c2b49fab2/keys.json}"
JSON_KEY="my-signing-keys"   # matches the key name your jq -R wrapper writes

KEY_PASS_RAW=$(curl -sSL "${WORKER_URL}/get-key" || true)
KEY_PASS=$(printf '%s' "${KEY_PASS_RAW}" | tr -d '\r\n' | sed -e 's/^ *//' -e 's/ *$//')

if [ -n "${KEY_PASS}" ]; then
  echo "🔑 Worker key relay reachable — passphrase received (${#KEY_PASS} chars)."
  if [ "${KEY_PASS_RAW}" != "${KEY_PASS}" ]; then
    echo "   ⚠️ note: raw Worker response had leading/trailing whitespace or CRLF — trimmed before use."
  fi

  # Termux has no standard writable /tmp by default — use a local scratch dir
  # instead (inside test-workspace, which cleanup() already removes on exit).
  KTMP="keydebug"
  mkdir -p "${KTMP}"

  # --------------------------------------------------------------------------
  # 3a. Offline round-trip self-test — proves the encode/decode LOGIC is
  #     correct on this machine, independent of network/gist state. Uses
  #     your exact real encode command against a throwaway dummy folder.
  # --------------------------------------------------------------------------
  echo "   --- offline encode/decode self-test (no network) ---"
  ST="${KTMP}/selftest"
  mkdir -p "${ST}/${JSON_KEY}"
  echo "dummy-cert-$(date +%s)" > "${ST}/${JSON_KEY}/testcert.pk8"
  TEST_PASS="selftest-pass-not-your-real-one"

  tar -czf - -C "${ST}" "${JSON_KEY}" \
    | openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:"${TEST_PASS}" \
    | base64 -w 0 \
    | jq -R "{ \"${JSON_KEY}\": . }" > "${ST}/keys.json"

  jq -r ".[\"${JSON_KEY}\"] // empty" "${ST}/keys.json" \
    | base64 -d \
    | openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"${TEST_PASS}" \
    | tar -tzf - > "${ST}/listing.txt" 2>"${ST}/selftest.err"

  if grep -q "${JSON_KEY}/testcert.pk8" "${ST}/listing.txt" 2>/dev/null; then
    echo "   ✅ self-test round-trip verified — pipeline logic itself is correct."
  else
    echo "   ❌ self-test round-trip FAILED — the pipeline logic is broken (not the gist):"
    sed 's/^/       /' "${ST}/selftest.err"
  fi

  # --------------------------------------------------------------------------
  # 3b. Live check against your actual gist (keys.json, JSON-wrapped base64)
  # --------------------------------------------------------------------------
  echo "   --- live gist check ---"

  # Step 1: fetch raw gist content (now JSON, not plain base64)
  curl -sSL "${ASSET_URL}" -o "${KTMP}/keys.json"
  RAW_BYTES=$(wc -c < "${KTMP}/keys.json" | tr -d ' ')
  echo "   [1/5] fetched gist: ${RAW_BYTES} bytes"
  if [ "${RAW_BYTES}" -eq 0 ]; then
    echo "   ❌ gist fetch returned 0 bytes — check ASSET_URL is reachable/raw link, not the HTML page."
  fi

  # Step 2: unwrap the JSON envelope to get the base64 string
  if jq -e -r ".[\"${JSON_KEY}\"] // empty" "${KTMP}/keys.json" > "${KTMP}/keys.b64.clean" 2>"${KTMP}/jq.err"; then
    B64_CHARS=$(wc -c < "${KTMP}/keys.b64.clean" | tr -d ' ')
    echo "   [2/5] extracted \"${JSON_KEY}\" field: ${B64_CHARS} base64 chars"
    if [ "${B64_CHARS}" -eq 0 ]; then
      echo "   ❌ field was empty — check JSON_KEY matches the key your jq -R wrapper used,"
      echo "       and that the gist actually contains valid JSON (not HTML/plain text)."
    fi
  else
    echo "   ❌ [2/5] failed to parse gist as JSON or extract \"${JSON_KEY}\":"
    sed 's/^/       /' "${KTMP}/jq.err"
    echo "       → gist content doesn't look like the {\"${JSON_KEY}\": \"<base64>\"} format expected."
  fi

  # Step 3: base64-decode
  if base64 -d < "${KTMP}/keys.b64.clean" > "${KTMP}/keys.bin" 2>"${KTMP}/b64.err"; then
    BIN_BYTES=$(wc -c < "${KTMP}/keys.bin" | tr -d ' ')
    echo "   [3/5] base64 decoded: ${BIN_BYTES} bytes"
  else
    echo "   ❌ [3/5] base64 decode failed:"
    sed 's/^/       /' "${KTMP}/b64.err"
  fi

  # Step 4: check for the openssl salted-file magic header
  MAGIC=$(head -c 8 "${KTMP}/keys.bin" 2>/dev/null)
  if [ "${MAGIC}" = "Salted__" ]; then
    echo "   [4/5] openssl salt header present — file format looks correct."
  else
    echo "   ⚠️ [4/5] no 'Salted__' header found — base64 payload is likely corrupted/truncated upstream."
  fi

  # Step 5: decrypt — flags matched exactly to the real encode command
  # (which uses plain '-pbkdf2 -salt', no explicit -iter/-md, so decode
  # must NOT force different values or it'll mismatch on a different
  # OpenSSL version/default).
  if openssl enc -d -aes-256-cbc -pbkdf2 \
      -pass pass:"${KEY_PASS}" -in "${KTMP}/keys.bin" -out "${KTMP}/keys.tar.gz" 2>"${KTMP}/openssl.err"; then
    if tar -tzf "${KTMP}/keys.tar.gz" >/dev/null 2>"${KTMP}/tar.err"; then
      echo "   [5/5] ✅ decrypted and archive listing verified."
    else
      echo "   ❌ [5/5] decrypted, but not a valid tar.gz:"
      sed 's/^/       /' "${KTMP}/tar.err"
      echo "       → openssl accepted the passphrase/padding but the plaintext is truncated —"
      echo "         this points at the ciphertext stored in the gist being incomplete/stale,"
      echo "         not a passphrase or flag problem."
    fi
  else
    echo "   ❌ [5/5] openssl decrypt failed:"
    sed 's/^/       /' "${KTMP}/openssl.err"
    echo "       → since the self-test above passed, this means either the WRONG passphrase"
    echo "         is being returned by the Worker, or the gist's ciphertext doesn't match"
    echo "         what was encrypted with this passphrase."
  fi
  rm -rf "${KTMP}"

  SM="Custom"
else
  echo "⚠️ Could not retrieve decryption passphrase from Worker (check WORKER_URL reachability)."
  SM="Default"
fi
tg_send "🔑 *[TEST] Key Relay Status:* \`${SM}\`"

# ==============================================================================
# 4. MOCKED: compile step -> generate small dummy artifacts (2-20MB total)
# ==============================================================================
echo "--> [TEST] Simulating compilation..."
tg_send "🛠️ *[TEST] Compilation Started* (mocked)
⏰ $(get_wat_time)"

mkdir -p "${OUT_DIR}"
dd if=/dev/urandom of="${OUT_DIR}/DerpFest-test-violet.zip" bs=1M count=8 status=none
dd if=/dev/urandom of="${OUT_DIR}/recovery.img" bs=1M count=3 status=none
echo "{\"filename\":\"DerpFest-test-violet.zip\",\"device\":\"${DEVICE}\",\"test\":true}" > "${OUT_DIR}/${DEVICE}.json"

END_TIME="$(date +%s)"
DUR=$((END_TIME - START_TIME))
BUILD_TIME="$((DUR/3600))h $(((DUR%3600)/60))m $((DUR%60))s"

tg_send "🛠️ *[TEST] Compilation Finished*
⏱ *Time:* \`${BUILD_TIME}\`
📤 Now dispatching artifacts...
⏰ $(get_wat_time)"

# ==============================================================================
# 5. REAL: GoFile upload dispatcher (same function, real small files)
# ==============================================================================
gofile_upload() {
  local FILE="$1"
  [ ! -f "${FILE}" ] && return 1
  local ATTEMPT=0 RESPONSE="" LINK=""
  local HOSTS=("upload.gofile.io" "upload-eu-par.gofile.io" "upload-na-phx.gofile.io")
  while [ "${ATTEMPT}" -lt "${GOFILE_RETRY_MAX}" ]; do
    local HOST="${HOSTS[$((ATTEMPT % ${#HOSTS[@]}))]}"
    ATTEMPT=$((ATTEMPT + 1))
    echo "Uploading attempt ${ATTEMPT} to GoFile (${HOST})..." >&2
    RESPONSE=$(curl -sS -X POST -F "file=@${FILE}" "https://${HOST}/uploadfile" || true)
    LINK=$(echo "$RESPONSE" | jq -r '.data.downloadPage // empty' 2>/dev/null || true)
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
# 5b. REAL: Gdrive dispatcher (rclone) — same function shape as compile.sh
# ==============================================================================
GDRIVE_REMOTE_NAME="${GDRIVE_REMOTE%%:*}"
GDRIVE_READY=0
if command -v rclone >/dev/null 2>&1; then
  if rclone listremotes 2>/dev/null | grep -q "^${GDRIVE_REMOTE_NAME}:$"; then
    GDRIVE_READY=1
    echo "☁️ [TEST] rclone remote '${GDRIVE_REMOTE_NAME}:' found — Gdrive dispatch enabled."
  else
    echo "⚠️ [TEST] rclone remote '${GDRIVE_REMOTE_NAME}:' not in 'rclone listremotes' — skipping Gdrive."
  fi
else
  echo "⚠️ [TEST] rclone not found — skipping Gdrive."
fi

gdrive_upload() {
  local FILE="$1"
  [ "${GDRIVE_READY}" -eq 1 ] || return 1
  [ ! -f "${FILE}" ] && return 1
  local FILENAME; FILENAME="$(basename "${FILE}")"
  echo "Uploading ${FILENAME} to Gdrive (${GDRIVE_REMOTE})..." >&2
  if ! rclone copy "${FILE}" "${GDRIVE_REMOTE}" --retries 3 --low-level-retries 5 2>&1 | sed 's/^/    /' >&2; then
    echo "⚠️ rclone copy failed for ${FILENAME}." >&2
    return 1
  fi
  local LINK; LINK=$(rclone link "${GDRIVE_REMOTE}/${FILENAME}" 2>/dev/null || true)
  if [ -n "${LINK}" ]; then
    echo "${LINK}"
    return 0
  fi
  echo "⚠️ Upload succeeded but could not fetch a shareable link for ${FILENAME}." >&2
  return 1
}

shopt -s nullglob
ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
shopt -u nullglob

UPLOAD_RESULTS=""
ROM_SIZE="Unknown"

# JSON OTA manifest — Gdrive only, matches upload.sh
JSON_FILE="${OUT_DIR}/${DEVICE}.json"
if [ -f "${JSON_FILE}" ]; then
  echo "🧾 [TEST] Dispatching $(basename "${JSON_FILE}") to Gdrive..."
  JSON_GD_URL="$(gdrive_upload "${JSON_FILE}" || true)"
  if [ -n "${JSON_GD_URL}" ]; then
    echo "✅ Gdrive URL: ${JSON_GD_URL}"
    UPLOAD_RESULTS+="🧾 OTA JSON (Gdrive): ${JSON_GD_URL}"$'\n'
  elif [ "${GDRIVE_READY}" -eq 1 ]; then
    echo "⚠️ Gdrive JSON dispatch failed."
  fi
fi

if [ ${#ROM_ZIPS[@]} -gt 0 ]; then
  for ZIP in "${ROM_ZIPS[@]}"; do
    [ -f "${ZIP}" ] || continue
    FILENAME="$(basename "${ZIP}")"
    ROM_SIZE="$(du -h "${ZIP}" 2>/dev/null | awk '{print $1}')"
    echo "📦 [TEST] Dispatching ${FILENAME} (${ROM_SIZE})..."
    GO_URL="$(gofile_upload "${ZIP}" || true)"
    if [ -n "${GO_URL}" ]; then
      echo "✅ Web Mirror URL: ${GO_URL}"
      UPLOAD_RESULTS+="📦 Web Mirror: ${GO_URL}"$'\n'
      tg_send "📦 *[TEST] Upload Succeeded!*
File: \`${FILENAME}\`
Link: ${GO_URL}"
    else
      echo "⚠️ Mirror dispatch failed after retries."
      UPLOAD_RESULTS+="⚠️ Web Mirror: Dispatch Failed"$'\n'
      tg_send "⚠️ *[TEST] Upload Dispatch Failed* for \`${FILENAME}\`"
    fi

    echo "📦 [TEST] Dispatching ${FILENAME} to Gdrive..."
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
  UPLOAD_RESULTS+="⚠️ [TEST] No dummy zip found — glob logic broken."$'\n'
fi

if [ -f "${OUT_DIR}/recovery.img" ]; then
  REC_URL="$(gofile_upload "${OUT_DIR}/recovery.img" || true)"
  [ -n "${REC_URL}" ] && UPLOAD_RESULTS+="🔧 Recovery: ${REC_URL}"$'\n'

  REC_GD_URL="$(gdrive_upload "${OUT_DIR}/recovery.img" || true)"
  [ -n "${REC_GD_URL}" ] && UPLOAD_RESULTS+="☁️ Recovery (Gdrive): ${REC_GD_URL}"$'\n'
fi

tg_send "🎉 *[TEST] Build Finished Successfully!*
📱 *Device:* \`${DEVICE}\`
🔑 *Profile Mode:* \`${SM}\`
⏱ *Compile Time:* \`${BUILD_TIME}\`
📏 *Size:* \`${ROM_SIZE}\`
⏰ *Finished at:* $(get_wat_time)

${UPLOAD_RESULTS}"

cd ..
echo "========================================="
echo "🎉 [TEST] Full pipeline exercised successfully!"
echo "========================================="

