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