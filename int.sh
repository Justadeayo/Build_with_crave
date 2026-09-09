#!/usr/bin/env bash

set -e
export TZ="Africa/Lagos"

# Color definitions for visual terminal feedback
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# 0. MASTER IDENTITY POINTER (SINGLE SECRET GIST)
# ==============================================================================
PROFILE_URL="${PROFILE_URL:-https://gist.githubusercontent.com/Justadeayo/}"

echo -e "${BLUE}🌐 Sourcing target profile into memory...${NC}"
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
LOG_FILE="build.log"

TMP_DIR="$(mktemp -d -t build-XXXXXX 2>/dev/null || mktemp -d)"

get_wat_time() {
  TZ="Africa/Lagos" date +'%Y-%m-%d %H:%M:%S WAT'
}

format_time() {
  local SECS=$1
  local h=$(( SECS / 3600 ))
  local m=$(( (SECS % 3600) / 60 ))
  local s=$(( SECS % 60 ))
  [ "$h" -gt 0 ] && echo "${h}h ${m}m ${s}s" || echo "${m}m ${s}s"
}

# ==============================================================================
# NOTIFICATION & INTERACTIVE TELEGRAM DISPATCHERS
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

tg_send_with_button() {
  local msg="$1"
  if [ -n "${DS}" ] && [ -n "${CT}" ]; then
    curl -sS -X POST "https://api.telegram.org/bot${DS}/sendMessage" \
      -d chat_id="${CT}" \
      -d parse_mode="Markdown" \
      -d disable_web_page_preview="true" \
      --data-urlencode "text=${msg}" \
      -d reply_markup='{"inline_keyboard": [[{"text": "🔄 Refresh Info", "callback_data": "refresh"}]]}' | jq -r '.result.message_id // empty' 2>/dev/null || true
  fi
}

tg_edit_with_button() {
  local msg_id="$1"
  local msg="$2"
  if [ -n "${DS}" ] && [ -n "${CT}" ] && [ -n "${msg_id}" ]; then
    curl -sS -X POST "https://api.telegram.org/bot${DS}/editMessageText" \
      -d chat_id="${CT}" \
      -d message_id="${msg_id}" \
      -d parse_mode="Markdown" \
      -d disable_web_page_preview="true" \
      --data-urlencode "text=${msg}" \
      -d reply_markup='{"inline_keyboard": [[{"text": "🔄 Refresh Info", "callback_data": "refresh"}]]}' >/dev/null 2>&1 || true
  fi
}

# ==============================================================================
# TELEMETRY & LIVE MONITORS
# ==============================================================================
get_stats() {
  read -r _ u1 n1 s1 i1 w1 irq1 sirq1 st1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 irq2 sirq2 st2 _ < /proc/stat

  idle1=$((i1 + w1))
  idle2=$((i2 + w2))
  total1=$((u1 + n1 + s1 + i1 + w1 + irq1 + sirq1 + st1))
  total2=$((u2 + n2 + s2 + i2 + w2 + irq2 + sirq2 + st2))

  diff_idle=$((idle2 - idle1))
  diff_total=$((total2 - total1))

  local CPU=0
  [ "$diff_total" -gt 0 ] && CPU=$(( 100 * (diff_total - diff_idle) / diff_total ))

  MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
  MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  LOAD=$(cut -d' ' -f1 /proc/loadavg)
  echo "$CPU|$MEM_USED|$MEM_TOTAL|$LOAD"
}

listen_refresh() {
  local OFFSET=0
  while true; do
    UPDATES=$(curl -s "https://api.telegram.org/bot${DS}/getUpdates?offset=${OFFSET}")
    COUNT=$(echo "$UPDATES" | jq '.result | length 2>/dev/null' || echo 0)

    if [ "$COUNT" -gt 0 ]; then
      for ((i=0; i<COUNT; i++)); do
        UPDATE=$(echo "$UPDATES" | jq -c ".result[$i]")
        UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
        OFFSET=$((UPDATE_ID + 1))

        CALLBACK=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
        MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')

        if [ "$CALLBACK" = "refresh" ]; then
          CALLBACK_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
          curl -s -X POST "https://api.telegram.org/bot${DS}/answerCallbackQuery" \
               -d callback_query_id="$CALLBACK_ID" >/dev/null 2>&1 || true

          STATS=$(get_stats)
          CPU=$(echo "$STATS" | cut -d'|' -f1)
          MEM_USED=$(echo "$STATS" | cut -d'|' -f2)
          MEM_TOTAL=$(echo "$STATS" | cut -d'|' -f3)
          LOAD=$(echo "$STATS" | cut -d'|' -f4)

          ELAPSED=$(( $(date +%s) - START_TIME ))
          CONSOLE=$(grep -v '^\s*$' "$LOG_FILE" 2>/dev/null | tail -n1 | cut -c1-110 || echo "Compilation running...")
          NOW_LOCAL=$(get_wat_time)

          tg_edit_with_button "$MSG_ID" "⚙️ *Building ${ROM_NAME}*

📱 *Device:* \`${DEVICE}\`
🏙️ *Build Type:* \`${BUILD_TYPE}\`

*Server Stats*
💻 *CPU:* \`${CPU}%\`
💾 *RAM:* \`${MEM_USED}MB / ${MEM_TOTAL}MB\`
⚡ *Load:* \`${LOAD}\`

🕛 *Elapsed:* $(format_time "$ELAPSED")
🔥 *Status:* Compiling...
📟 *Console:* \`${CONSOLE}\`

🔄 *Last Refreshed:* \`${NOW_LOCAL}\`"
        fi
      done
    fi
    sleep 2
  done
}

# ==============================================================================
# SECURE CLEANUP FUNCTION & ERROR TRAP
# ==============================================================================
cleanup() {
  local exit_code=$?

  [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" 2>/dev/null || true

  if [ "$exit_code" -ne 0 ]; then
    echo -e "${RED}❌ Script aborted with exit code ${exit_code}.${NC}"
    tg_send "🚨 *Build Failed!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\`
⚠️ *Exit Code:* \`${exit_code}\`
⏰ *Failed at:* $(get_wat_time)"
  fi

  echo -e "${YELLOW}🧹 Wiping temporary files, keys, and sensitive environment variables...${NC}"
  rm -rf "${TMP_DIR}" 2>/dev/null || true
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
  echo -e "${BLUE}--> Executing: ${step_name}...${NC}"
  if ! "$@"; then
    echo -e "${RED}❌ Step failed: ${step_name}${NC}"
    exit 1
  fi
}

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Starting $ROM_NAME Build for $DEVICE ${NC}"
echo -e "${GREEN}=========================================${NC}"

PROGRESS_MSG_ID=$(tg_send_with_button "🚀 *Initializing Build...*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\`
⏰ *Started at:* $(get_wat_time)

Tap 🔄 *Refresh Info* to update live server performance!")

# ==============================================================================
# 1. CLEANUP & SOURCE SYNC
# ==============================================================================
echo -e "${YELLOW}--> Cleaning up workspace and hardware paths...${NC}"
find .repo/ -name "*.lock" -delete 2>/dev/null || true
rm -rf .repo/local_manifests \
       vendor/MiuiCamera \
       hardware/xiaomi \
       hardware/dolby \
       vendor/lineage-priv/keys 2>/dev/null || true

run_step "Initializing Repository" repo init -u "${REPO_MANIFEST_URL}" -b "${REPO_MANIFEST_BRANCH}" --git-lfs --depth=1

echo -e "${BLUE}--> Fetching local device manifests...${NC}"
git clone --depth=1 -b "${MANIFEST_LOCAL_BRANCH}" "${MANIFEST_LOCAL_REPO}" .repo/local_manifests || true

if [ -f /opt/crave/resync.sh ]; then
  run_step "Resyncing Sources" /opt/crave/resync.sh
else
  run_step "Syncing Sources" repo sync -c --force-sync --no-tags --no-clone-bundle -j"${JOBS}"
fi

# ==============================================================================
# 2. HARDWARE TREES & PATCHES
# ==============================================================================
echo -e "${BLUE}--> Fetching custom hardware repos...${NC}"
rm -rf hardware/xiaomi
run_step "Cloning Xiaomi Hardware" git clone https://github.com/Evolution-X-Devices/hardware_xiaomi -b bka-no-dolby hardware/xiaomi
rm -rf hardware/xiaomi/packages/DSPVolumeSynchronizer

rm -rf hardware/dolby
run_step "Cloning Dolby Hardware" git clone https://github.com/adi8900/hardware_dolby -b lunaris hardware/dolby
echo -e "${GREEN}✅ Hardware paths configured!${NC}"

# ==============================================================================
# 3. VERIFICATION ASSETS SETUP
# ==============================================================================
echo -e "${BLUE}--> Initializing build environment assets...${NC}"
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
  echo -e "${GREEN}=====================================${NC}"
  echo -e "${GREEN}✅ Target output verification profile active ($KEY_COUNT assets)!${NC}"
  echo -e "${GREEN}=====================================${NC}"
  export PRODUCT_DEFAULT_DEV_CERTIFICATE=vendor/lineage-priv/keys/releasekey
  SM="Custom"
else
  echo -e "${YELLOW}=====================================${NC}"
  echo -e "${YELLOW}⚠️ Standard verification profile active.${NC}"
  echo -e "${YELLOW}=====================================${NC}"
  SM="Default"
fi

# ==============================================================================
# 4. BUILD COMPILATION (FORCE WAT TIMESTAMPS & LIVE DISPATCH)
# ==============================================================================
echo -e "${BLUE}--> Setting up build environment...${NC}"

export TZ="Africa/Lagos"
export LC_ALL="C.UTF-8"
export BUILD_DATETIME_FILE="${TMP_DIR}/build_date"
date +%s > "${BUILD_DATETIME_FILE}"

. build/envsetup.sh

run_step "Selecting Target Device" lunch "lineage_${DEVICE}-bp4a-user"
run_step "Performing Installclean" make installclean

# Initialize log file and launch background listener
touch "$LOG_FILE"
listen_refresh &
LISTENER_PID=$!

echo -e "${GREEN}🔥 Starting ROM Compilation...${NC}"
if command -v mka >/dev/null 2>&1; then
  run_step "Compiling ROM" bash -c "mka derp -j${JOBS} 2>&1 | tee ${LOG_FILE}"
else
  run_step "Compiling ROM" bash -c "make -j${JOBS} derp 2>&1 | tee ${LOG_FILE}"
fi

# Stop polling daemon safely after completion
kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true

END_TIME="$(date +%s)"
DUR=$((END_TIME - START_TIME))
BUILD_TIME="$(format_time $DUR)"

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

    echo -e "${BLUE}Uploading attempt ${ATTEMPT} to GoFile...${NC}"
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
echo -e "${BLUE}--> Processing build artifacts...${NC}"

shopt -s nullglob
ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
shopt -u nullglob

UPLOAD_RESULTS=""
ROM_SIZE="Unknown"

if [ ${#ROM_ZIPS[@]} -gt 0 ]; then
  for ZIP in "${ROM_ZIPS[@]}"; do
    [ -f "${ZIP}" ] || continue
    FILENAME="$(basename "${ZIP}")"
    ROM_SIZE="$(du -h "${ZIP}" 2>/dev/null | awk '{print $1}')"

    echo -e "${BLUE}📦 Dispatching ${FILENAME} to Web Mirror (GoFile)...${NC}"
    GO_URL="$(gofile_upload "${ZIP}" || true)"
    if [ -n "${GO_URL}" ]; then
      echo -e "${GREEN}✅ Web Mirror URL: ${GO_URL}${NC}"
      UPLOAD_RESULTS+="📦 Web Mirror: ${GO_URL}"$'\n'
    else
      echo -e "${YELLOW}⚠️ Mirror dispatch failed after retries.${NC}"
      UPLOAD_RESULTS+="⚠️ Web Mirror: Dispatch Failed (Saved locally)"$'\n'
    fi
  done
else
  UPLOAD_RESULTS+="⚠️ Build Output: No target archive detected."$'\n'
fi

if [ -f "${OUT_DIR}/recovery.img" ]; then
  echo -e "${BLUE}🔧 Dispatching recovery.img to GoFile...${NC}"
  REC_URL="$(gofile_upload "${OUT_DIR}/recovery.img" || true)"
  [ -n "${REC_URL}" ] && UPLOAD_RESULTS+="🔧 Recovery: ${REC_URL}"$'\n'
fi

if [ -f "${OUT_DIR}/violet.json" ] && [ -n "${DS:-}" ] && [ -n "${CT:-}" ]; then
  echo -e "${BLUE}📄 Sending violet.json to Telegram...${NC}"
  curl -sS -X POST "https://api.telegram.org/bot${DS}/sendDocument" \
    -F chat_id="${CT}" \
    -F document=@"${OUT_DIR}/violet.json" \
    -F caption="📄 *OTA JSON Metadata for ${DEVICE}*" \
    -F parse_mode="Markdown" >/dev/null 2>&1 || true
fi

tg_send "🎉 *Build Finished Successfully!*
📱 *Device:* \`${DEVICE}\`
🔑 *Profile Mode:* \`${SM}\` (${KEY_COUNT:-0} keys)
⏱ *Compilation Time:* \`${BUILD_TIME}\`
📏 *Size:* \`${ROM_SIZE}\`
⏰ *Finished at:* $(get_wat_time)

${UPLOAD_RESULTS}"

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}🎉 Process finished successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
