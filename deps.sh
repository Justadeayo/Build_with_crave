#!/usr/bin/env bash

# ==============================================================================
# deps.sh — DEPENDENCY CHECK ( warn only, no install)
# ==============================================================================

check_and_install_deps() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || echo "⚠️ Warning: $tool is not installed"
  done

  if ! command -v repo >/dev/null 2>&1; then
    echo "⚠️ 'repo' not found on PATH — expected to be preinstalled in the Crave build image."
    echo "If this isn't Crave, install it manually before continuing."
    echo "But this Crave, you don't have a choice 😉"
  fi
  return 0
}
