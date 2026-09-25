#!/usr/bin/env bash
# ==============================================================================
# clang_repair.sh — HOST CLANG GUARD + KERNEL CLANG GUARD
# ==============================================================================

# ---- Host clang (fixes "Unable to find libclang" in libbinder_ndk_bindgen) ----
HOST_CLANG_PRJ="prebuilts/clang/host/linux-x86"
HOST_CLANG_NAME="clang-r584948"
HOST_CLANG_TAG="refs/tags/android-17.0.0_r1"
HOST_CLANG_DIR="${HOST_CLANG_PRJ}/${HOST_CLANG_NAME}"
HOST_CLANG_WHY=""
HOST_CLANG_FIXED_BY=""

host_clang_ok() {
  HOST_CLANG_WHY=""
  if ! "${HOST_CLANG_DIR}/bin/clang" --version >/dev/null 2>&1; then
    HOST_CLANG_WHY="bin/clang missing or will not run"; return 1
  fi

  local so
  so="$(find -L "${HOST_CLANG_DIR}/lib" -maxdepth 1 -name 'libclang.so*' -size +1M 2>/dev/null | head -1)"
  if [ -z "${so}" ]; then
    HOST_CLANG_WHY="no real libclang.so in lib/"; return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    exec 9>&2; exec 2>/dev/null
    python3 -c "import ctypes,sys; ctypes.CDLL(sys.argv[1])" "${so}" >/dev/null 2>&1
    local load_rc=$?
    exec 2>&9 9>&-
    if [ "${load_rc}" -ne 0 ]; then
      HOST_CLANG_WHY="libclang.so present but will not load (corrupt/truncated)"; return 1
    fi
  elif ! (readelf -h "${so}" >/dev/null 2>&1 && nm -D "${so}" >/dev/null 2>&1); then
    HOST_CLANG_WHY="libclang.so present but fails ELF/symbol check (corrupt/truncated)"; return 1
  fi
  if ! ls "${HOST_CLANG_DIR}"/lib/clang/*/include/stdbool.h >/dev/null 2>&1; then
    HOST_CLANG_WHY="builtin headers missing in lib/clang"; return 1
  fi
  return 0
}




repair_host_clang() {
  local name

  echo "--> Repair 1/3: restoring ${HOST_CLANG_NAME} from git objects already in the workspace..."
  git -C "${HOST_CLANG_PRJ}" checkout HEAD -- "${HOST_CLANG_NAME}" 2>&1 | tail -3 || true
  if host_clang_ok; then HOST_CLANG_FIXED_BY="1/3 (git restore)"; return 0; fi

  echo "--> Repair 2/3: wiping the clang project + repo's copy of it, then re-cloning..."
  name="$(repo list -n "${HOST_CLANG_PRJ}" 2>/dev/null | head -1)"
  rm -rf "${HOST_CLANG_PRJ}" ".repo/projects/${HOST_CLANG_PRJ}.git"
  if [ -n "${name}" ]; then rm -rf ".repo/project-objects/${name}.git"; fi
  repo sync -c --force-sync --no-tags --no-clone-bundle -j4 "${HOST_CLANG_PRJ}" || true
  if host_clang_ok; then HOST_CLANG_FIXED_BY="2/3 (re-clone)"; return 0; fi

  echo "--> Repair 3/3: downloading ${HOST_CLANG_NAME} straight from Google..."
  rm -rf "${HOST_CLANG_DIR}"
  mkdir -p "${HOST_CLANG_DIR}"
  curl -fsSL --retry 3 -o host-clang.tgz \
    "https://android.googlesource.com/platform/${HOST_CLANG_PRJ}/+archive/${HOST_CLANG_TAG}/${HOST_CLANG_NAME}.tar.gz" \
    && tar -xzf host-clang.tgz -C "${HOST_CLANG_DIR}" || true
  rm -f host-clang.tgz
  if host_clang_ok; then HOST_CLANG_FIXED_BY="3/3 (Google download)"; return 0; fi

  return 1
}




setup_host_clang() {
  if host_clang_ok; then
    echo "✅ Host ${HOST_CLANG_NAME} is complete."
    return 0
  fi

  local CLANG_WHY="${HOST_CLANG_WHY}"
  echo "⚠️ Host ${HOST_CLANG_NAME} incomplete (${CLANG_WHY}) - repairing before the build..."

  local CLANG_DIFF_LOG
  CLANG_DIFF_LOG=$(git -C "${HOST_CLANG_PRJ}" status --short -- "${HOST_CLANG_NAME}" 2>&1 | head -20 || true)
  CLANG_DIFF_LOG="${CLANG_DIFF_LOG:-(none - git sees no differences)}"
  echo "${CLANG_DIFF_LOG}"

  tg_send "⚠️ *Host ${HOST_CLANG_NAME} incomplete* (${CLANG_WHY}) - repairing before build
\`\`\`
${CLANG_DIFF_LOG}
\`\`\`" || true

  if ! repair_host_clang; then
    echo "❌ Could not repair ${HOST_CLANG_NAME} (${HOST_CLANG_WHY}); bindgen would fail, so stopping now."
    tg_send "❌ Could not repair ${HOST_CLANG_NAME} (${HOST_CLANG_WHY}); bindgen would fail." || true
    exit 1
  fi
  echo "✅ Host ${HOST_CLANG_NAME} repaired by repair ${HOST_CLANG_FIXED_BY}."
  tg_send "✅ Host ${HOST_CLANG_NAME} repaired by repair ${HOST_CLANG_FIXED_BY}." || true
}

# ---- Kernel clang (r416183b) ----
KERNEL_CLANG_DIR="prebuilts/clang/host/linux-x86/clang-r416183b"
KERNEL_CLANG_WHY=""
KERNEL_CLANG_FIXED_BY=""
KERNEL_CLANG_AOSP_COMMIT="8fd13dca1a6dfbc43fc54b2408d49199981c387b"




kernel_clang_ok() {
  KERNEL_CLANG_WHY=""
  if [ ! -x "${KERNEL_CLANG_DIR}/bin/clang" ]; then
    KERNEL_CLANG_WHY="bin/clang missing or not executable"; return 1
  fi

  local log rc out
  log=$(mktemp)
  exec 9>&2; exec 2>/dev/null
  LD_LIBRARY_PATH="${KERNEL_CLANG_DIR}/lib64:${LD_LIBRARY_PATH:-}" \
    "${KERNEL_CLANG_DIR}/bin/clang" --target=aarch64-linux-gnu \
    -fstack-protector-strong -Werror \
    -Wno-error=unused-command-line-argument -Wno-unused-command-line-argument \
    -c -x c /dev/null -o /dev/null \
    >"${log}" 2>&1
  rc=$?
  exec 2>&9 9>&-
  if [ "${rc}" -ne 0 ]; then
    out="$(cat "${log}")"
    KERNEL_CLANG_WHY="self-test compile failed (exit ${rc}): ${out:-no output, likely crashed}"
    rm -f "${log}"
    return 1
  fi
  rm -f "${log}"
  return 0
}




repair_kernel_clang() {
  echo "--> Repair 1/2: re-cloning kernel clang-r416183b from LineageOS (GitHub)..."
  rm -rf "${KERNEL_CLANG_DIR}"
  git clone --depth=1 https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b.git "${KERNEL_CLANG_DIR}"
  if kernel_clang_ok; then KERNEL_CLANG_FIXED_BY="1/2 (LineageOS re-clone)"; return 0; fi

  echo "--> Repair 2/2: downloading clang-r416183b straight from Google (AOSP prebuilts history)..."
  rm -rf "${KERNEL_CLANG_DIR}"
  mkdir -p "${KERNEL_CLANG_DIR}"
  curl -fsSL --retry 3 -o kernel-clang.tgz \
    "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${KERNEL_CLANG_AOSP_COMMIT}/clang-r416183b.tar.gz" \
    && tar -xzf kernel-clang.tgz -C "${KERNEL_CLANG_DIR}" || true
  rm -f kernel-clang.tgz
  if kernel_clang_ok; then KERNEL_CLANG_FIXED_BY="2/2 (Google AOSP download)"; return 0; fi

  return 1
}




setup_kernel_clang() {
  echo "--> Ensuring kernel-specific clang (r416183b) is available and working..."
  if kernel_clang_ok; then
    echo "✅ Kernel clang-r416183b is present and passes its compile self-test."
  else
    echo "⚠️ Kernel clang-r416183b problem: ${KERNEL_CLANG_WHY}"
    tg_send "⚠️ *Kernel clang-r416183b problem*: ${KERNEL_CLANG_WHY}
Repairing before build..." || true
    if ! repair_kernel_clang; then
      echo "❌ Kernel clang-r416183b still broken after both repairs (${KERNEL_CLANG_WHY}); stopping now."
      tg_send "❌ Kernel clang-r416183b still broken after both repairs: ${KERNEL_CLANG_WHY}" || true
      exit 1
    fi
    echo "✅ Kernel clang-r416183b repaired by repair ${KERNEL_CLANG_FIXED_BY}."
    tg_send "✅ Kernel clang-r416183b repaired by repair ${KERNEL_CLANG_FIXED_BY}." || true
  fi
  file "${KERNEL_CLANG_DIR}/bin/clang"
}
