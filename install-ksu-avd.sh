#!/bin/bash
# Install KernelSU kernel + matching modules into AVD
# Uses the running AVD's own tools (cpio, lz4) to repack the ramdisk
#
# Usage:
#   1. Start your AVD normally: emulator -avd <name>
#   2. Run: ./install-ksu-avd.sh <artifact-dir>
#   3. Reboot AVD
#
# Example: ./install-ksu-avd.sh ./6.1.162-android14-2026-03-x86_64

set -e

ARTIFACT_DIR="${1:-.}"
ADB="${ADB:-adb}"

# Validate
KERNEL=""
[ -f "$ARTIFACT_DIR/bzImage" ] && KERNEL="$ARTIFACT_DIR/bzImage"
[ -f "$ARTIFACT_DIR/Image" ] && KERNEL="$ARTIFACT_DIR/Image"
[ -z "$KERNEL" ] && { echo "ERROR: No kernel in $ARTIFACT_DIR"; exit 1; }
[ -d "$ARTIFACT_DIR/modules" ] || { echo "ERROR: No modules/ in $ARTIFACT_DIR"; exit 1; }

echo "=== AVD KernelSU Installer ==="
echo "Kernel: $KERNEL ($(wc -c < "$KERNEL") bytes)"
echo "Modules: $(ls "$ARTIFACT_DIR/modules/"*.ko 2>/dev/null | wc -l) .ko files"
echo ""

# Check ADB
echo "[1/6] Checking ADB..."
$ADB devices | grep -q "device$" || { echo "ERROR: No AVD connected. Start it first."; exit 1; }
$ADB root && sleep 2
echo "  Connected as root"

# Push modules to AVD
echo "[2/6] Pushing modules to AVD..."
$ADB shell "rm -rf /data/local/tmp/ksu && mkdir -p /data/local/tmp/ksu/modules"
for f in "$ARTIFACT_DIR/modules"/*; do
  $ADB push "$f" "/data/local/tmp/ksu/modules/$(basename "$f")" >/dev/null 2>&1
done
echo "  Pushed $(ls "$ARTIFACT_DIR/modules/"*.ko | wc -l) modules"

# Push the stock ramdisk to AVD for repacking
echo "[3/6] Pushing ramdisk to AVD for repacking..."

# Find system image path
AVD_NAME=$($ADB shell getprop ro.boot.qemu.avd_name 2>/dev/null | tr -d '\r\n')
echo "  AVD name: $AVD_NAME"

# Find SDK path
SDK=""
for p in "$ANDROID_SDK_ROOT" "$ANDROID_HOME" "$LOCALAPPDATA/Android/Sdk" "$HOME/Android/Sdk"; do
  [ -d "$p" ] && SDK="$p" && break
done
[ -z "$SDK" ] && { echo "ERROR: Android SDK not found"; exit 1; }

# Find system image from AVD config
AVD_DIR=""
for p in "$HOME/.android/avd/${AVD_NAME}.avd" "$USERPROFILE/.android/avd/${AVD_NAME}.avd"; do
  [ -d "$p" ] && AVD_DIR="$p" && break
done
[ -z "$AVD_DIR" ] && { echo "ERROR: AVD dir not found for $AVD_NAME"; exit 1; }

SYSDIR=$(grep "image.sysdir.1" "$AVD_DIR/config.ini" | cut -d= -f2 | tr -d '[:space:]')
SYSIMG="$SDK/$SYSDIR"
RAMDISK="$SYSIMG/ramdisk.img"
echo "  System image: $SYSIMG"

# Backup
[ ! -f "$SYSIMG/kernel-ranchu.bak" ] && cp "$SYSIMG/kernel-ranchu" "$SYSIMG/kernel-ranchu.bak"
[ ! -f "$RAMDISK.bak" ] && cp "$RAMDISK" "$RAMDISK.bak"

# Push ramdisk to AVD
$ADB push "$RAMDISK.bak" /data/local/tmp/ksu/ramdisk.img
echo "  Pushed ramdisk.img"

# Repack ramdisk inside AVD
echo "[4/6] Repacking ramdisk inside AVD..."
$ADB shell << 'AVDSCRIPT'
set -e
cd /data/local/tmp/ksu

echo "  Decompressing ramdisk..."
# Detect format and decompress
MAGIC=$(xxd -l4 -p ramdisk.img)
case "$MAGIC" in
  02214c18) # LZ4 legacy
    lz4 -d ramdisk.img ramdisk.cpio 2>/dev/null || {
      # Try manual legacy decompression
      dd if=ramdisk.img bs=1 skip=8 2>/dev/null | lz4 -d - ramdisk.cpio 2>/dev/null || {
        echo "  Trying alternative lz4..."
        # Skip 4-byte magic + 4-byte block size
        python3 -c "
import sys
data = open('ramdisk.img','rb').read()
# LZ4 legacy: magic(4) + blocks of [size(4) + compressed_data]
pos = 4
out = b''
while pos < len(data):
    bsz = int.from_bytes(data[pos:pos+4], 'little')
    pos += 4
    if bsz == 0 or bsz > len(data): break
    out += data[pos:pos+bsz]  # these are lz4 blocks
    pos += bsz
open('ramdisk.raw','wb').write(out)
" 2>/dev/null && lz4 -d ramdisk.raw ramdisk.cpio 2>/dev/null
      }
    }
    ;;
  1f8b*) # gzip
    gzip -dc ramdisk.img > ramdisk.cpio
    ;;
  *) # try as raw cpio
    cp ramdisk.img ramdisk.cpio
    ;;
esac

if [ ! -f ramdisk.cpio ]; then
  echo "ERROR: Failed to decompress ramdisk"
  exit 1
fi
echo "  Decompressed: $(wc -c < ramdisk.cpio) bytes"

# Extract CPIO
mkdir -p extract
cd extract
cpio -idm < ../ramdisk.cpio 2>/dev/null
echo "  Extracted files:"
find . -type f | head -20

# Add our modules
echo "  Adding matching modules..."
mkdir -p lib/modules
cp /data/local/tmp/ksu/modules/*.ko lib/modules/ 2>/dev/null || true
cp /data/local/tmp/ksu/modules/modules.* lib/modules/ 2>/dev/null || true

# Create modules.load if missing
if [ ! -f lib/modules/modules.load ]; then
  ls lib/modules/*.ko 2>/dev/null | xargs -n1 basename > lib/modules/modules.load 2>/dev/null || true
fi

echo "  Modules in ramdisk: $(ls lib/modules/*.ko 2>/dev/null | wc -l)"

# Repack CPIO
echo "  Repacking CPIO..."
find . | cpio -o -H newc 2>/dev/null > ../ramdisk-new.cpio
echo "  New CPIO: $(wc -c < ../ramdisk-new.cpio) bytes"

cd ..

# Compress back to LZ4
echo "  Compressing with LZ4..."
lz4 -l -12 ramdisk-new.cpio ramdisk-new.img 2>/dev/null || {
  # fallback: gzip
  echo "  LZ4 failed, using gzip..."
  gzip -c ramdisk-new.cpio > ramdisk-new.img
}
echo "  New ramdisk: $(wc -c < ramdisk-new.img) bytes"

echo "  DONE inside AVD"
AVDSCRIPT

echo "  Ramdisk repacked"

# Pull repacked ramdisk
echo "[5/6] Pulling repacked ramdisk..."
$ADB pull /data/local/tmp/ksu/ramdisk-new.img "$RAMDISK"
echo "  Installed new ramdisk.img"

# Install kernel
echo "[6/6] Installing KernelSU kernel..."
cp "$KERNEL" "$SYSIMG/kernel-ranchu"
echo "  Installed kernel-ranchu"

# Cleanup
$ADB shell "rm -rf /data/local/tmp/ksu" 2>/dev/null || true

echo ""
echo "=========================================="
echo "  Installation Complete!"
echo "=========================================="
echo ""
echo "Now close the emulator and restart:"
echo "  emulator -avd $AVD_NAME -no-snapshot-load -show-kernel"
echo ""
echo "To restore original kernel:"
echo "  cp '$SYSIMG/kernel-ranchu.bak' '$SYSIMG/kernel-ranchu'"
echo "  cp '$RAMDISK.bak' '$RAMDISK'"
echo ""
