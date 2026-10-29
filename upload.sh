#!/usr/bin/env bash

# ==============================================================================
# upload.sh — SOURCEFORGE DISPATCHER, TELEGRAM FILE SEND, ARTIFACT HANDLING
# ==============================================================================

SF_USER="${SF_USER:-justus-26}"
SF_PROJECT="${SF_PROJECT:-derp-violet}"
SF_RECOVERY_DIR="${SF_RECOVERY_DIR:-recovery-derp}"
SF_KEY="${SF_KEY:-$(pwd)/.ssh/sourceforge_ed25519}"

sf_upload() {
  local FILE="$1" SUB="${2:-}" FNAME DEST_DIR SSH DEST URL CODE i
  [ -n "${SF_USER:-}" ] || { echo "❌ SF_USER is not set" >&2; return 1; }
  [ -f "${FILE}" ] || { echo "❌ File not found: ${FILE}" >&2; return 1; }

  FNAME=$(basename "${FILE}")
  DEST_DIR="${SUB:+$SUB/}"
  SSH="ssh -i ${SF_KEY} -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30"
  DEST="${SF_USER},${SF_PROJECT}@frs.sourceforge.net:/home/frs/project/${SF_PROJECT}/${DEST_DIR}"

  for i in 1 2 3 4 5; do
    rsync -a --partial --timeout=120 --chmod=D755,F644 -e "${SSH}" "${FILE}" "${DEST}" >&2 && break
    [ "${i}" -eq 5 ] && return 1
    echo "SourceForge attempt ${i} failed, retrying in 30s..." >&2
    sleep 30
  done

  URL="https://sourceforge.net/projects/${SF_PROJECT}/files/${DEST_DIR}${FNAME}/download"
  CODE=$(curl -sL -r 0-0 -o /dev/null -w '%{http_code}' "${URL}" || true)
  case "${CODE}" in
    200|206) ;;
    *) echo "⚠️ URL check returned HTTP ${CODE} (may just be indexing lag): ${URL}" >&2 ;;
  esac
  echo "${URL}"
}

update_ota_json() {
  local ZIP="$1" URL="$2" JSON="${OUT_DIR}/${DEVICE}.json"
  [ -f "${JSON}" ] || return 0

  local SIZE
  SIZE=$(stat -c %s "${ZIP}")
  jq --arg url "${URL}" --arg id "${ROM_SHA}" --arg fn "$(basename "${ZIP}")" \
     --argjson size "${SIZE}" --argjson dt "$(date +%s)" '
    if has("response") then
      .response[0] += {url:$url, id:$id, filename:$fn, size:$size, datetime:$dt}
    else
      . + {url:$url, id:$id, filename:$fn, size:$size, datetime:$dt}
    end' "${JSON}" > "${JSON}.tmp" && mv "${JSON}.tmp" "${JSON}" \
    || { rm -f "${JSON}.tmp"; echo "⚠️ Could not update ${DEVICE}.json" >&2; return 1; }
}

tg_send_file() {
  local FILE="$1" CAPTION="$2" SIZE
  if [ ! -f "${FILE}" ]; then
    echo "⚠️ Not found: ${FILE}" >&2
    return 0
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    return 0
  fi
  SIZE=$(stat -c %s "${FILE}")
  if [ "${SIZE}" -gt 52428800 ]; then
    tg_send "⚠️ \`$(basename "${FILE}")\` is over 50 MB, not sent to Telegram."
    return 0
  fi
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "caption=${CAPTION}" \
    -F "document=@${FILE}" >/dev/null 2>&1 || true
}

crave_pull_if_missing() {
  local TARGET="$1"
  [ -f "${TARGET}" ] && return 0
  if command -v crave >/dev/null 2>&1; then
    echo "--> ${TARGET} not found locally — attempting 'crave pull'..."
    crave pull "${TARGET}" "$(dirname "${TARGET}")/" 2>/dev/null || true
  fi
}

dispatch_artifacts() {
  echo "--> Processing build artifacts..."

  local JSON_FILE="${OUT_DIR}/${DEVICE}.json"
  local ROM_ZIP="" ROM_LINK="" REC_FILE="" REC_LINK=""

  crave_pull_if_missing "${OUT_DIR}/recovery.img"
  crave_pull_if_missing "${JSON_FILE}"

  shopt -s nullglob
  local ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
  shopt -u nullglob

  if [ ${#ROM_ZIPS[@]} -eq 0 ] && command -v crave >/dev/null 2>&1; then
    echo "--> No local ROM zip found — attempting 'crave pull'..."
    crave pull "${OUT_DIR}"/DerpFest*.zip "${OUT_DIR}/" 2>/dev/null || true
    shopt -s nullglob
    ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
    shopt -u nullglob
  fi

  UPLOAD_RESULTS=""
  ROM_SIZE="Unknown"
  ROM_SHA=""

  if [ ${#ROM_ZIPS[@]} -eq 0 ]; then
    echo "ℹ️ No ROM zip found in ${OUT_DIR}."
    UPLOAD_RESULTS+="⚠️ Build Output: No target archive detected."$'\n'
  else
    ROM_ZIP="$(ls -t "${ROM_ZIPS[@]}" | head -1)"
    ROM_SIZE="$(du -h "${ROM_ZIP}" 2>/dev/null | awk '{print $1}')"
    ROM_SHA="$(sha256sum "${ROM_ZIP}" | cut -d' ' -f1)"

    echo "📦 Dispatching $(basename "${ROM_ZIP}") to SourceForge..."
    ROM_LINK="$(sf_upload "${ROM_ZIP}" "" || true)"
    if [ -n "${ROM_LINK}" ]; then
      echo "✅ SourceForge URL: ${ROM_LINK}"
      UPLOAD_RESULTS+="📤 SourceForge (ROM): ${ROM_LINK}"$'\n'
      UPLOAD_RESULTS+="🔐 SHA256: \`${ROM_SHA}\`"$'\n'
    else
      echo "⚠️ SourceForge ROM upload failed."
      UPLOAD_RESULTS+="⚠️ SourceForge (ROM): upload failed"$'\n'
    fi

    if [ -n "${ROM_LINK}" ]; then
      if [ -f "${JSON_FILE}" ]; then
        update_ota_json "${ROM_ZIP}" "${ROM_LINK}" || true
        tg_send_file "${JSON_FILE}" "OTA json" || true
      else
        echo "ℹ️ No OTA JSON manifest found at ${JSON_FILE} — skipping."
      fi
    fi
  fi

  if [ -f "${OUT_DIR}/recovery.img" ]; then
    echo "🔧 Dispatching recovery.img to SourceForge..."
    REC_FILE="${OUT_DIR}/derp-recovery-$(date +%Y%m%d).img"
    cp "${OUT_DIR}/recovery.img" "${REC_FILE}"
    REC_LINK="$(sf_upload "${REC_FILE}" "${SF_RECOVERY_DIR}" || true)"
    rm -f "${REC_FILE}"
    if [ -n "${REC_LINK}" ]; then
      UPLOAD_RESULTS+="🧰 Recovery (SourceForge): ${REC_LINK}"$'\n'
    else
      UPLOAD_RESULTS+="⚠️ Recovery (SourceForge): upload failed"$'\n'
    fi
  fi
}
