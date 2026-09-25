#!/usr/bin/env bash
# ==============================================================================
# upload.sh — GOFILE DISPATCHER, GDRIVE DISPATCHER, ARTIFACT HANDLING
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

GDRIVE_REMOTE_NAME=""
GDRIVE_READY=0

upload_init() {
  GDRIVE_REMOTE_NAME="${GDRIVE_REMOTE%%:*}"
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
}

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

  shopt -s nullglob
  local ROM_ZIPS=("${OUT_DIR}"/DerpFest*.zip)
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
    local JSON_GD_URL
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
    local ZIP FILENAME GO_URL GD_URL
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
    local REC_URL REC_GD_URL
    REC_URL="$(gofile_upload "${OUT_DIR}/recovery.img" || true)"
    [ -n "${REC_URL}" ] && UPLOAD_RESULTS+="🔧 Recovery: ${REC_URL}"$'\n'

    echo "🔧 Dispatching recovery.img to Gdrive..."
    REC_GD_URL="$(gdrive_upload "${OUT_DIR}/recovery.img" || true)"
    [ -n "${REC_GD_URL}" ] && UPLOAD_RESULTS+="☁️ Recovery (Gdrive): ${REC_GD_URL}"$'\n'
  fi
}
