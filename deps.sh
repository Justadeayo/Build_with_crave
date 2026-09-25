#!/usr/bin/env bash
# ==============================================================================
# deps.sh — DEPENDENCY CHECK (auto-install where possible)
# ==============================================================================
check_and_install_deps() {
  local missing=()
  for dep in "$@"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  echo "⚠️ Missing dependencies: ${missing[*]} — attempting install..."

  if command -v pkg >/dev/null 2>&1; then
    pkg install -y "${missing[@]}" || true
  elif command -v apt-get >/dev/null 2>&1; then
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
