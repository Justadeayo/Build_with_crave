#!/usr/bin/env bash
# ==============================================================================
# clang_repair.sh — HOST CLANG GUARD + KERNEL CLANG GUARD
# ==============================================================================

CLANG_PRJ="prebuilts/clang/host/linux-x86"
CLANG_TAG="refs/tags/android-17.0.0_r1"
CLANG_WHY=""
CLANG_FIXED_BY=""

clang_ok() {
  local dir="$1"
  CLANG_WHY=""
  if ! "${dir}/bin/clang" --version >/dev/null 2>&1; then
    CLANG_WHY="bin/clang missing or will not run"; return 1
  fi

  local so
  so="$(find -L "${dir}/lib" -maxdepth 1 -name 'libclang.so*' -size +1M 2>/dev/null | head -1)"
  if [ -z "${so}" ]; then
    CLANG_WHY="no real libclang.so in lib/"; return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    exec 9>&2; exec 2>/dev/null
    python3 -c "import ctypes,sys; ctypes.CDLL(sys.argv[1])" "${so}" >/dev/null 2>&1
    local load_rc=$?
    exec 2>&9 9>&-
    if [ "${load_rc}" -ne 0 ]; then
      CLANG_WHY="libclang.so present but will not load (corrupt/truncated)"; return 1
    fi
  elif ! (readelf -h "${so}" >/dev/null 2>&1 && nm -D "${so}" >/dev/null 2>&1); then
    CLANG_WHY="libclang.so present but fails ELF/symbol check (corrupt/truncated)"; return 1
  fi
  if ! ls "${dir}"/lib/clang/*/include/stdbool.h >/dev/null 2>&1; then
    CLANG_WHY="builtin headers missing in lib/clang"; return 1
  fi
  return 0
}



repair_clang() {
  local prj="$1" name="$2" tag="$3" dir="$4"

  echo "--> Repair 1/2: restoring ${name} from git objects already in the workspace..."
  git -C "${prj}" checkout HEAD -- "${name}" 2>&1 | tail -3 || true
  if clang_ok "${dir}"; then CLANG_FIXED_BY="1/2 (git restore)"; return 0; fi

  echo "--> Repair 2/2: downloading ${name} straight from Google..."
  rm -rf "${dir}"
  mkdir -p "${dir}"
  curl -fsSL --retry 3 -o clang-dl.tgz \
    "https://android.googlesource.com/platform/${prj}/+archive/${tag}/${name}.tar.gz" \
    && tar -xzf clang-dl.tgz -C "${dir}" || true
  rm -f clang-dl.tgz
  if clang_ok "${dir}"; then CLANG_FIXED_BY="2/2 (Google download)"; return 0; fi

  return 1
}



ensure_clang() {
  local prj="$1" name="$2" tag="$3" dir="${1}/${2}"

  if clang_ok "${dir}"; then
    echo "✅ ${name} is complete."
    return 0
  fi
  local why="${CLANG_WHY}"
  echo "⚠️ ${name} incomplete (${why}) - repairing before the build..."

  local diff_log
  diff_log=$(git -C "${prj}" status --short -- "${name}" 2>&1 | head -20 || true)
  diff_log="${diff_log:-(none - git sees no differences)}"
  echo "${diff_log}"

  tg_send "⚠️ *${name} incomplete* (${why}) - repairing before build
\`\`\`
${diff_log}
\`\`\`" || true

  if ! repair_clang "${prj}" "${name}" "${tag}" "${dir}"; then
    echo "❌ Could not repair ${name} (${CLANG_WHY}); build would fail, so stopping now."
    tg_send "❌ Could not repair ${name} (${CLANG_WHY}); build would fail." || true
    exit 1
  fi
  echo "✅ ${name} repaired by repair ${CLANG_FIXED_BY}."
  tg_send "✅ ${name} repaired by repair ${CLANG_FIXED_BY}." || true
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






CROSS_TOOLS="arm-linux-gnueabi-gcc arm-linux-gnueabi-ld aarch64-linux-gnu-gcc aarch64-linux-gnu-ld aarch64-linux-gnu-elfedit"
missing_tools() {
  local t out=""
  for t in ${CROSS_TOOLS}; do
    command -v "${t}" >/dev/null 2>&1 || out="${out} ${t}"
  done
  echo "${out# }"
}
if [ -n "$(missing_tools)" ]; then
  echo "⚠️ Missing cross tools: $(missing_tools) — attempting install..."
  sudo apt-get update -qq && sudo apt-get install -y gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu || true
  if [ -z "$(missing_tools)" ]; then
    echo "✅ Cross toolchains ready."
  else
    echo "⚠️ Still missing: $(missing_tools) — the inline kernel build will fail."
  fi
fi