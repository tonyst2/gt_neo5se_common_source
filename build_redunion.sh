#!/bin/bash
# Build script for RedUnion kernel (realme GT Neo5 SE / RMX3700, waipio/sm8475).
#
# Builds this common-source tree against gki_defconfig with clang/lld,
# then packages the result into a flashable AnyKernel3 zip.
#
# Requires drivers/soc/oplus/storage (symlinked in this repo to
# ../../../../../vendor/oplus/kernel/storage, matching realme's real
# kernel_platform/{common,vendor} sibling layout) to resolve to a real
# checkout of the vendor-source repo. Point VENDOR_ROOT at a checkout of
# https://github.com/realme-kernel-opensource/realme_gt_neo5se-AndroidV-vendor-source
# (or the OPLUS-equivalent from the WildKernels/OnePlus manifests) if you
# are not building from inside the exact kernel_platform/{common,vendor}
# layout already.
set -euo pipefail

KERNEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_NAME="${KERNEL_NAME:-RedUnion}"
VENDOR_ROOT="${VENDOR_ROOT:-}"
OUT_DIR="${OUT_DIR:-$KERNEL_ROOT/../out}"
JOBS="${JOBS:-$(nproc)}"
ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/osm0sis/AnyKernel3.git}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-$KERNEL_ROOT/../AnyKernel3}"
DEVICE_NAMES="${DEVICE_NAMES:-RMX3700 RMX3700CN RMX3700PU}"
IS_SLOT_DEVICE="${IS_SLOT_DEVICE:-1}"

log() { echo "[redunion-build] $*"; }
err() { echo "[redunion-build] ERROR: $*" >&2; exit 1; }

# --- 1. toolchain: find a clang and make it callable without a version suffix ---
find_bin() {
	local name="$1"
	command -v "$name" 2>/dev/null && return 0
	compgen -c 2>/dev/null | grep -E "^${name}-[0-9]+$" | sort -V | tail -1
}

TOOLCHAIN_BIN="$KERNEL_ROOT/.build-toolchain-bin"
mkdir -p "$TOOLCHAIN_BIN"
for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip llvm-cov llvm-addr2line llvm-ranlib; do
	found="$(find_bin "$tool")" || true
	[ -n "$found" ] && ln -sf "$(command -v "$found")" "$TOOLCHAIN_BIN/$tool"
done
[ -x "$TOOLCHAIN_BIN/clang" ] || err "no clang found on PATH (need clang or clang-<ver>)"
export PATH="$TOOLCHAIN_BIN:$PATH"
log "using $(clang --version | head -1)"

command -v aarch64-linux-gnu-ld >/dev/null || err "binutils-aarch64-linux-gnu not installed"

# --- 2. vendor symlink (drivers/soc/oplus/storage) for defconfig to parse ---
STORAGE_LINK="$KERNEL_ROOT/drivers/soc/oplus/storage"
RESTORE_LINK=0
if [ ! -e "$STORAGE_LINK/Kconfig" ]; then
	[ -n "$VENDOR_ROOT" ] || err "drivers/soc/oplus/storage doesn't resolve and VENDOR_ROOT wasn't given. Set VENDOR_ROOT=/path/to/vendor-source checkout."
	VENDOR_STORAGE="$VENDOR_ROOT/vendor/oplus/kernel/storage"
	[ -d "$VENDOR_STORAGE" ] || err "no vendor/oplus/kernel/storage under VENDOR_ROOT=$VENDOR_ROOT"
	log "relinking drivers/soc/oplus/storage -> $VENDOR_STORAGE for this build"
	ln -sfn "$VENDOR_STORAGE" "$STORAGE_LINK"
	RESTORE_LINK=1
fi
cleanup() {
	if [ "$RESTORE_LINK" = 1 ]; then
		log "restoring tracked (relative) storage symlink"
		git -C "$KERNEL_ROOT" checkout -- drivers/soc/oplus/storage 2>/dev/null || true
	fi
}
trap cleanup EXIT

# --- 3. configure + build ---
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
MAKE_ARGS=(ARCH=arm64 SUBARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 O="$OUT_DIR")

log "generating gki_defconfig"
make -C "$KERNEL_ROOT" "${MAKE_ARGS[@]}" gki_defconfig

log "building (-j$JOBS)"
make -C "$KERNEL_ROOT" "${MAKE_ARGS[@]}" -j"$JOBS"

IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"
[ -f "$IMAGE" ] || err "build finished but $IMAGE is missing"
log "kernel built: $IMAGE ($(du -h "$IMAGE" | cut -f1))"

# --- 4. package into AnyKernel3 ---
if [ ! -d "$ANYKERNEL_DIR" ]; then
	log "cloning AnyKernel3 template"
	git clone --depth 1 "$ANYKERNEL_REPO" "$ANYKERNEL_DIR"
fi
rm -rf "$ANYKERNEL_DIR/.git" "$ANYKERNEL_DIR/ramdisk"/* "$ANYKERNEL_DIR"/*.zip
mkdir -p "$ANYKERNEL_DIR/ramdisk"

KVER="$(make -C "$KERNEL_ROOT" "${MAKE_ARGS[@]}" -s kernelversion)"
KSTRING="$KERNEL_NAME Kernel for realme GT Neo5 SE (RMX3700), $KVER"
DEV_PROPS=""
i=1
for d in $DEVICE_NAMES; do
	DEV_PROPS="${DEV_PROPS}device.name${i}=${d}
"
	i=$((i+1))
done

cat > "$ANYKERNEL_DIR/anykernel.sh" <<EOF
### AnyKernel3 Ramdisk Mod Script
## $KERNEL_NAME kernel for realme GT Neo5 SE (RMX3700)

properties() { '
kernel.string=$KSTRING
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
${DEV_PROPS}supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

boot_attributes() {
set_perm_recursive 0 0 755 644 \$RAMDISK/*;
set_perm_recursive 0 0 750 750 \$RAMDISK/init* \$RAMDISK/sbin;
} # end attributes

BLOCK=boot;
IS_SLOT_DEVICE=$IS_SLOT_DEVICE;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

split_boot; # GKI boot.img has no ramdisk (it lives in init_boot); only swap the kernel Image
flash_boot;
EOF

cp "$IMAGE" "$ANYKERNEL_DIR/Image.gz"

ZIP_NAME="${KERNEL_NAME}-RMX3700-${KVER}-$(date +%Y%m%d).zip"
ZIP_PATH="$KERNEL_ROOT/../$ZIP_NAME"
( cd "$ANYKERNEL_DIR" && rm -f "$ZIP_PATH" && zip -r9 "$ZIP_PATH" . -x ".git*" >/dev/null )

log "done: $ZIP_PATH"
