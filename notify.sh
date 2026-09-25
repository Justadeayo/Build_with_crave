#!/usr/bin/env bash
# ==============================================================================
# notify.sh — NOTIFICATION & CREDENTIAL SETUP, STEP/CLEANUP WRAPPERS, DISPLAY
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

get_wat_time() {
  TZ="Africa/Lagos" date +'%Y-%m-%d %H:%M:%S WAT'
}

# ---- Display helpers ----
CYAN="\033[1;36m"
BOLD="\033[1m"
RESET="\033[0m"

_center() {
  local text="$1" width="$2" len pad
  len=${#text}
  pad=$(( (width - len) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%s\n" "${pad}" "" "${text}"
}

banner() {
  local rom="$1" device="$2" branch="$3"
  local W=66 

  clear 2>/dev/null || true
  echo -e "${CYAN}${BOLD}"
  cat <<'EOF'
 ██████╗ ███████╗██████╗ ██████╗ ███████╗███████╗███████╗████████╗
 ██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝██╔════╝╚══██╔══╝
 ██║  ██║█████╗  ██████╔╝██████╔╝█████╗  █████╗  ███████╗   ██║
 ██║  ██║██╔══╝  ██╔══██╗██╔═══╝ ██╔══╝  ██╔══╝  ╚════██║   ██║
 ██████╔╝███████╗██║  ██║██║     ██║     ███████╗███████║   ██║
 ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝     ╚══════╝╚══════╝   ╚═╝
EOF
  echo ""
  _center "built by Justus26 🔥" "${W}"
  echo ""

  local l1="ROM    : ${rom} (Android 17)"
  local l2="Device : ${device}"
  local l3="Branch : ${branch}"
  local info_w=0 l
  for l in "${l1}" "${l2}" "${l3}"; do (( ${#l} > info_w )) && info_w=${#l}; done
  local indent=$(( (W - info_w) / 2 ))
  (( indent < 0 )) && indent=0
  printf "%*s%s\n" "${indent}" "" "${l1}"
  printf "%*s%s\n" "${indent}" "" "${l2}"
  printf "%*s%s\n" "${indent}" "" "${l3}"
  echo ""
  echo -e "${RESET}"
}

BANNER_TG="🅳🅴🅁🅿🅵🅴🆂🆃"

banner_tg() {
  local rom="$1" device="$2" branch="$3"
  tg_send "${BANNER_TG}
🔥 built by Justus26
📦 *${rom}* (Android 17)
📱 *${device}*
🌿 \`${branch}\`
⏰ $(get_wat_time)"
}

section() {
  echo ""
  echo "====================================="
  echo "   $1"
  echo "====================================="
}




# ==============================================================================
# SECURE ERROR TRAP
# ==============================================================================
cleanup() {
  local exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "❌ Script aborted with exit code ${exit_code}."
    tg_send "🚨 *Build Failed!*
📱 *Device:* \`${DEVICE}\`
📦 *ROM:* \`${ROM_NAME}\` (Android 17)
⚠️ *Exit Code:* \`${exit_code}\`
⏰ *Failed at:* $(get_wat_time)"
  fi
}




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
