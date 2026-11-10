#!/usr/bin/env bash
# build_8821cu_gki.sh
#
# Builds 8821cu.ko (RTL8821CU, morrownr driver; station + monitor mode + injection)
# for a Xiaomi 13T running the stock GKI kernel:
#   5.10.136-android12-9-00020-gc9f59ef34367-ab9585114
#
# Runs on Fedora (x86_64). Usage:
#   chmod +x build_8821cu_gki.sh
#   ./build_8821cu_gki.sh
#
# Optional environment variables:
#   CONFIG_GZ=/path/config.gz   Your phone's /proc/config.gz (strongly recommended;
#                               otherwise generic gki_defconfig is used)
#   PHONE_KO=/path/cfg80211.ko  A .ko pulled from the phone (e.g. cfg80211.ko from
#                               /vendor_dlkm/lib/modules/). Used to verify that the
#                               built module's symbol CRCs match your running kernel.
#   WORKDIR=/path               Where to build (default: ./rtl8821cu-build). Needs ~25 GB.
#   JOBS=N                      Parallel jobs (default: nproc). LTO linking is RAM-hungry;
#                               use 16 GB+ RAM or lower JOBS.
#   CLANG_DIR=/path/to/clang    Use this toolchain (dir containing bin/clang, bin/ld.lld).
#   USE_SYSTEM_CLANG=1          Skip the attempt to fetch Google's clang r416183b.
#   SKIP_DNF=1                  Do not run dnf.
#   QUICK=1                     Skip the full kernel build (minutes instead of hours). The
#                               module gets no symbol CRCs, so the kernel cannot detect an
#                               ABI mismatch: a wrong build may crash/reboot the phone
#                               instead of failing cleanly. Unverified; use at own risk.
#   FORCE_THIN_LTO=1            Switch the phone's full-LTO config to ThinLTO (needs much
#                               less RAM). Use only if the full-LTO build runs out of memory.

set -euo pipefail

# ---------------------------------------------------------------- constants
ACK_COMMIT="c9f59ef34367711a2a12a99162af152917d40dbc"   # android12-5.10-2022-11_r7
ACK_URLS=(
  "https://android.googlesource.com/kernel/common"
  "https://github.com/aosp-mirror/kernel_common"
)
LOCALVER="-android12-9-00020-gc9f59ef34367-ab9585114"
EXPECT_VERMAGIC="5.10.136${LOCALVER} SMP preempt mod_unload modversions aarch64"
DRV_URL="https://github.com/morrownr/8821cu-20210916"
ANDROID_CLANG_REPO="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
ANDROID_CLANG_BRANCH="android12-release"
ANDROID_CLANG_VER="clang-r416183b"

WORKDIR="${WORKDIR:-$PWD/rtl8821cu-build}"
JOBS="${JOBS:-$(nproc)}"
ACK="$WORKDIR/ack"
OUT="$WORKDIR/out"
DRV="$WORKDIR/8821cu"
RESULT_DIR="$PWD/output"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
ACK="$WORKDIR/ack"; OUT="$WORKDIR/out"; DRV="$WORKDIR/8821cu"

# ---------------------------------------------------------------- 1. packages
if [ -z "${SKIP_DNF:-}" ]; then
  say "Installing build dependencies with dnf (sudo)"
  sudo dnf install -y \
    git make gcc clang lld llvm flex bison bc perl-core python3 \
    openssl-devel elfutils-libelf-devel elfutils-devel ncurses-devel \
    cpio rsync kmod diffutils findutils patch which xz zstd gzip
  # Newer Fedora splits OpenSSL's ENGINE header (needed by the kernel's extract-cert) out
  sudo dnf install -y openssl-devel-engine || warn "openssl-devel-engine not available; build may fail on openssl/engine.h"
fi

for t in git make clang ld.lld flex bison bc zcat modinfo; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done

# ---------------------------------------------------------------- 2. kernel source
say "Fetching GKI kernel source (commit ${ACK_COMMIT:0:12})"
mkdir -p "$ACK"
[ -d "$ACK/.git" ] || git -C "$ACK" init -q
if [ "$(git -C "$ACK" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$ACK_COMMIT" ]; then
  ok=0
  for url in "${ACK_URLS[@]}"; do
    echo "trying $url"
    if git -C "$ACK" fetch --depth 1 "$url" "$ACK_COMMIT"; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || die "could not fetch kernel source from any mirror"
  git -C "$ACK" checkout -q --detach FETCH_HEAD
fi
[ "$(git -C "$ACK" rev-parse HEAD)" = "$ACK_COMMIT" ] || die "wrong kernel commit checked out"

# ---------------------------------------------------------------- 3. toolchain
if [ -n "${CLANG_DIR:-}" ]; then
  export PATH="$CLANG_DIR/bin:$PATH"
elif [ -z "${USE_SYSTEM_CLANG:-}" ]; then
  TC="$WORKDIR/toolchain"
  if [ ! -x "$TC/$ANDROID_CLANG_VER/bin/clang" ]; then
    say "Trying to fetch Google's $ANDROID_CLANG_VER (falls back to system clang on failure)"
    rm -rf "$TC"
    if git clone --depth 1 --filter=blob:none --sparse -b "$ANDROID_CLANG_BRANCH" \
           "$ANDROID_CLANG_REPO" "$TC" \
       && git -C "$TC" sparse-checkout set "$ANDROID_CLANG_VER" \
       && [ -x "$TC/$ANDROID_CLANG_VER/bin/clang" ]; then
      echo "got $ANDROID_CLANG_VER"
    else
      warn "could not get $ANDROID_CLANG_VER; using system clang"
      rm -rf "$TC"
    fi
  fi
  [ -x "$TC/$ANDROID_CLANG_VER/bin/clang" ] && export PATH="$TC/$ANDROID_CLANG_VER/bin:$PATH"
fi
say "Toolchain"
clang --version | head -1
ld.lld --version | head -1

mk() {
  make -C "$ACK" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
       CROSS_COMPILE=aarch64-linux-gnu- "$@"
}

# ---------------------------------------------------------------- 4. kernel config
say "Configuring kernel"
mkdir -p "$OUT"
if [ -n "${CONFIG_GZ:-}" ]; then
  [ -f "$CONFIG_GZ" ] || die "CONFIG_GZ not found: $CONFIG_GZ"
  echo "using phone config: $CONFIG_GZ"
  zcat "$CONFIG_GZ" > "$OUT/.config"
else
  warn "no CONFIG_GZ given: using generic gki_defconfig. If the module is rejected"
  warn "with 'disagrees about version of symbol', rerun with your phone's config.gz."
  mk gki_defconfig
fi
"$ACK/scripts/config" --file "$OUT/.config" \
  --set-str LOCALVERSION "$LOCALVER" --disable LOCALVERSION_AUTO
if [ -n "${FORCE_THIN_LTO:-}" ]; then
  warn "FORCE_THIN_LTO set: switching LTO_CLANG_FULL -> LTO_CLANG_THIN (less RAM; CRCs not verified identical)"
  "$ACK/scripts/config" --file "$OUT/.config" --disable LTO_CLANG_FULL --enable LTO_CLANG_THIN
fi
mk olddefconfig

# The phone's config trims the kernel's exported symbols to Google's KMI whitelist
# (CONFIG_UNUSED_KSYMS_WHITELIST points at a file that only exists on Google's build
# server). Disable trimming so the build can run and Module.symvers is complete. The
# CRCs themselves are unaffected; whether the PHONE actually exports every symbol the
# driver needs is checked separately at the end (see the final instructions).
if grep -q '^CONFIG_TRIM_UNUSED_KSYMS=y' "$OUT/.config"; then
  warn "disabling CONFIG_TRIM_UNUSED_KSYMS (whitelist file is not available here)"
  "$ACK/scripts/config" --file "$OUT/.config" --disable TRIM_UNUSED_KSYMS --set-str UNUSED_KSYMS_WHITELIST ""
  mk olddefconfig
fi

# The phone's own cfg80211.ko was built with options we cannot read from config.gz (it has
# no cfg80211 section). A first build with defaults showed a CRC mismatch for wiphy_new_nm
# (it takes struct cfg80211_ops, which grows when NL80211_TESTMODE is on; MediaTek's wlan
# driver uses testmode). Extra scripts/config arguments for cfg80211 can be set here:
#   CFG80211_OPTS=""                                        -> no extra options
#   CFG80211_OPTS="--enable NL80211_TESTMODE --enable CFG80211_WEXT"   -> several
if [ -z "${CFG80211_OPTS+x}" ]; then CFG80211_OPTS="--enable NL80211_TESTMODE"; fi
# (applied further below, AFTER CFG80211 itself is enabled: these options depend on it,
#  so setting them first would be silently dropped by olddefconfig)

for opt in MODULES MODVERSIONS USB; do
  grep -Eq "^CONFIG_${opt}=(y|m)" "$OUT/.config" || die "CONFIG_${opt} is not enabled in this config"
done
# On the 13T, cfg80211 is a separately built, loadable module and config.gz reports
# "CONFIG_CFG80211 is not set". Enable it as a module so the wireless headers and
# Module.symvers include the cfg80211 exports the driver links against.
if ! grep -Eq '^CONFIG_CFG80211=(y|m)' "$OUT/.config"; then
  warn "CONFIG_CFG80211 not set in this config; enabling it as a module for the build"
  "$ACK/scripts/config" --file "$OUT/.config" --enable WIRELESS --module CFG80211
  mk olddefconfig
fi
if [ -n "$CFG80211_OPTS" ]; then
  echo "cfg80211 extra options: $CFG80211_OPTS"
  # shellcheck disable=SC2086
  "$ACK/scripts/config" --file "$OUT/.config" $CFG80211_OPTS
  mk olddefconfig
  # Fail loudly if an --enable option did not stick (e.g. a missing dependency)
  set -- $CFG80211_OPTS
  while [ $# -gt 0 ]; do
    case "$1" in
      --enable|-e) sym="$2"; shift 2
        grep -Eq "^CONFIG_${sym}=(y|m)" "$OUT/.config" || die "CONFIG_${sym} did not stick after olddefconfig (check its dependencies)";;
      *) shift;;
    esac
  done
fi
grep -E '^(# )?CONFIG_(LTO_CLANG_THIN|LTO_CLANG_FULL|CFI_CLANG|MODVERSIONS|MODULE_SIG|CFG80211|MAC80211|NL80211_TESTMODE|CFG80211_WEXT)[ =]' "$OUT/.config" || true

# ---------------------------------------------------------------- 5. build kernel (for Module.symvers)
say "Building kernel + in-tree modules (needed for exact symbol CRCs). This is the slow part."
if [ -n "${QUICK:-}" ]; then
  warn "QUICK=1: only preparing kernel headers; the module will have NO symbol CRCs (no ABI safety check)."
  mk -j"$JOBS" KCFLAGS="-Wno-error" modules_prepare
else
  mk -j"$JOBS" KCFLAGS="-Wno-error" Image modules
  [ -f "$OUT/Module.symvers" ] || die "Module.symvers was not produced"
fi

KREL="$(cat "$OUT/include/config/kernel.release" 2>/dev/null || echo unknown)"
echo "kernel.release = $KREL"
[ "$KREL" = "5.10.136${LOCALVER}" ] || warn "kernel.release differs from the phone's (expected 5.10.136${LOCALVER})"

# ---------------------------------------------------------------- 6. driver
say "Fetching and building the RTL8821CU driver"
if [ ! -d "$DRV/.git" ]; then
  git clone --depth 1 "$DRV_URL" "$DRV"
else
  git -C "$DRV" fetch --depth 1 origin && git -C "$DRV" reset -q --hard FETCH_HEAD
fi
git -C "$DRV" clean -fdxq

# Monitor mode + injection support must be compiled in
sed -i -E 's/^CONFIG_WIFI_MONITOR *=.*/CONFIG_WIFI_MONITOR = y/' "$DRV/Makefile"
grep -Eq '^CONFIG_WIFI_MONITOR *= *y' "$DRV/Makefile" || die "could not enable CONFIG_WIFI_MONITOR in driver Makefile"
grep -E '^CONFIG_(WIFI_MONITOR|PLATFORM_I386_PC|USB_HCI|CONCURRENT_MODE)' "$DRV/Makefile" || true

# The driver Makefile passes GCC-only warning flags (e.g. -Wno-enum-int-mismatch,
# -Wno-stringop-overread). Android clang 12 rejects unknown flags as errors under kbuild,
# so probe every "ccflags-y += -Wno-..." flag with the toolchain clang and drop rejected ones.
say "Removing warning flags the toolchain clang does not know"
dropped=0
while IFS= read -r flag; do
  if ! clang -Werror=unknown-warning-option "$flag" -x c -c /dev/null -o /dev/null 2>/dev/null; then
    echo "  dropping unsupported flag: $flag"
    sed -i -E "s|^([[:space:]]*ccflags-y[[:space:]]*\+=[[:space:]]*)${flag}([[:space:]#].*)?\$|#\1${flag}\2|" "$DRV/Makefile"
    dropped=$((dropped+1))
  fi
done < <(grep -hoE '^[[:space:]]*ccflags-y[[:space:]]*\+=[[:space:]]*-Wno-[A-Za-z0-9=_+-]+' "$DRV/Makefile" | grep -oE '\-Wno-[A-Za-z0-9=_+-]+' | sort -u)
echo "dropped $dropped unsupported flag(s)"
# Belt and braces: the two flags seen failing in practice must be gone
sed -i -E 's#^([[:space:]]*ccflags-y[[:space:]]*\+=[[:space:]]*-Wno-(enum-int-mismatch|stringop-overread))#\#\1#' "$DRV/Makefile"

# The generic (I386_PC) branch only sets little-endian/cfg80211 flags; ARCH is overridden by kbuild.
mk -j"$JOBS" M="$DRV" KCFLAGS="-Wno-error" ${QUICK:+KBUILD_MODPOST_WARN=1} modules

KO="$DRV/8821cu.ko"
[ -f "$KO" ] || die "8821cu.ko was not produced"
llvm-strip --strip-debug "$KO" 2>/dev/null || strip --strip-debug "$KO" || true

# ---------------------------------------------------------------- 7. verification
say "Verifying"
VM="$(modinfo -F vermagic "$KO")"
echo "module vermagic : $VM"
echo "phone vermagic  : $EXPECT_VERMAGIC"
# With CONFIG_MODVERSIONS the kernel ignores the release string (first word) and compares
# only the flags (SMP preempt mod_unload modversions aarch64) plus the symbol CRCs.
if [ "${VM#* }" = "${EXPECT_VERMAGIC#* }" ]; then
  echo "vermagic flags: MATCH"
  [ "${VM%% *}" = "${EXPECT_VERMAGIC%% *}" ] || warn "release string differs (harmless with modversions)"
else
  warn "vermagic FLAGS differ from the phone's. The module will be rejected."
fi

modprobe --dump-modversions "$KO" | sort -k2 > "$WORKDIR/mine.crc" || true
grep -qE '[[:space:]]module_layout$' "$WORKDIR/mine.crc" || warn "no module_layout CRC in module (modversions off?)"

if [ -n "${QUICK:-}" ]; then
  warn "QUICK mode: CRC cross-checks skipped. insmod may print 'no symbol version' warnings."
elif [ -n "${PHONE_KO:-}" ]; then
  [ -f "$PHONE_KO" ] || die "PHONE_KO not found: $PHONE_KO"
  # (a) CRCs the phone module REQUIRES from the kernel (imports) vs. what our module requires
  modprobe --dump-modversions "$PHONE_KO" | sort -k2 > "$WORKDIR/phone.crc"
  join -1 2 -2 2 <(awk '{print $1" "$2}' "$WORKDIR/mine.crc" | sort -k2) \
                 <(awk '{print $1" "$2}' "$WORKDIR/phone.crc" | sort -k2) \
    | awk '{ if ($2==$3) ok++; else {bad++; print "MISMATCH " $1 " mine=" $2 " phone=" $3} }
           END { printf "kernel symbols shared with phone module: %d compared, %d match, %d mismatch\n", ok+bad, ok, bad+0;
                 exit (bad>0) }' \
    && echo "import CRC check vs phone module: OK" \
    || warn "import CRC mismatches vs your phone's module (see above)."

  # (b) CRCs the phone module EXPORTS (e.g. cfg80211_*, wiphy_*) vs. what our module requires
  llvm-nm "$PHONE_KO" 2>/dev/null | awk '$3 ~ /^__crc_/ { s=substr($3,7); v=tolower($1); v="0x" substr(v, length(v)-7); print v, s }' \
    | sort -k2 > "$WORKDIR/phone_exports.crc"
  join -1 2 -2 2 <(awk '{print tolower($1)" "$2}' "$WORKDIR/mine.crc" | sort -k2) \
                 "$WORKDIR/phone_exports.crc" \
    | awk '{ if ($2==$3) ok++; else {bad++; print "EXPORT MISMATCH " $1 " mine=" $2 " phone-exports=" $3} }
           END { printf "symbols exported by the phone cfg80211: %d compared, %d match, %d mismatch\n", ok+bad, ok, bad+0;
                 if (ok+bad==0) exit 2; exit (bad>0) }' \
    && echo "export CRC check vs phone cfg80211: OK" \
    || warn "cfg80211 export CRC problem (see above): 'disagrees about version of symbol' is likely on insmod."
else
  warn "PHONE_KO not given: could not cross-check CRCs against your phone."
fi

# ---------------------------------------------------------------- 8. result
mkdir -p "$RESULT_DIR"
# Symbols the module needs from the running kernel / cfg80211 (checked on the phone below)
llvm-nm -u "$KO" | awk '{print $2}' | sort -u > "$RESULT_DIR/8821cu-undefined-symbols.txt"
cp -f "$KO" "$RESULT_DIR/8821cu.ko"
cp -f "$OUT/.config" "$RESULT_DIR/used-kernel-config"
cp -f "$WORKDIR/mine.crc" "$RESULT_DIR/8821cu-modversions.txt"

cat <<EOF

================================================================
Done:  $RESULT_DIR/8821cu.ko

STEP 1 - check the phone really exports every symbol the driver needs.
The stock kernel only exports Google's whitelisted symbols, so a symbol the driver
uses may be missing ("Unknown symbol" on insmod). Check BEFORE loading:

  adb push $RESULT_DIR/8821cu-undefined-symbols.txt /data/local/tmp/syms.txt
  adb shell
  su
  grep -o ' __ksymtab_[A-Za-z0-9_]*' /proc/kallsyms | sed 's/ __ksymtab_//' > /data/local/tmp/ksyms.txt
  grep -vxFf /data/local/tmp/ksyms.txt /data/local/tmp/syms.txt

Anything this prints is a symbol the phone does not export. Empty output = good.
If symbols are listed, send them to me; the driver then needs patching.

STEP 2 - load it (root shell on the ANDROID side, not inside the Kali chroot;
adapter plugged in via OTG):

  adb push $RESULT_DIR/8821cu.ko /data/local/tmp/
  adb shell
  su
  lsmod | grep cfg80211        # already loaded on this phone (comes from vendor_boot)
  insmod /data/local/tmp/8821cu.ko
  dmesg | tail -30

  # monitor mode + injection (iw / aircrack-ng / etc. must be available on the phone):
  ip link set wlan1 down
  iw dev wlan1 set type monitor
  ip link set wlan1 up
  iw dev wlan1 set channel 6

If insmod says "Invalid module format" or "disagrees about version of symbol",
check:  dmesg | tail   -- then rerun this script with CONFIG_GZ and PHONE_KO set.
================================================================
EOF
