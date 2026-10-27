#!/usr/bin/env bash
# Rebuilds linux.html. Needs: gcc-multilib flex bison bc libelf-dev libssl-dev cpio xz-utils make curl npm
# Stages are skipped if their output exists; delete work/<thing> to redo it.
# Env: KERNEL_TAG, ALPINE_BRANCH, JOBS
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd); W=$KIT/work; mkdir -p "$W"; cd "$W"
KERNEL_TAG=${KERNEL_TAG:-v6.1}; JOBS=${JOBS:-$(nproc)}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.24}
APK_PACKAGES=${APK_PACKAGES:-"gcc g++ musl-dev curl"}

# 1. v86 emulator + BIOS
[ -d package ] || { npm pack v86 >/dev/null && tar xzf v86-*.tgz; }
[ -f seabios.bin ] || curl -fsSL -O https://raw.githubusercontent.com/copy/v86/master/bios/seabios.bin
[ -f vgabios.bin ] || curl -fsSL -O https://raw.githubusercontent.com/copy/v86/master/bios/vgabios.bin

# 2. Alpine minirootfs (x86 / 32-bit, official, from alpinelinux/docker-alpine)
#    ALPINE_BRANCH can be v3.22, v3.23, v3.24, ... (any branch that has an x86/ dir)
if [ ! -f alpine.tgz ]; then
  F=$(curl -fsSL https://raw.githubusercontent.com/alpinelinux/docker-alpine/$ALPINE_BRANCH/x86/Dockerfile | awk '/^ADD/{print $2}')
  curl -fsSL -o alpine.tgz https://raw.githubusercontent.com/alpinelinux/docker-alpine/$ALPINE_BRANCH/x86/$F
fi

# 3. rootfs = Alpine + everything in overlay/ (add your own files/binaries/.apk there)
rm -rf rootfs; mkdir rootfs; tar xzf alpine.tgz -C rootfs --numeric-owner
cp -a "$KIT"/overlay/. rootfs/; mkdir -p rootfs/host; chmod +x rootfs/init rootfs/etc/v86-sysinit rootfs/bin/startsh
grep -q startsh rootfs/etc/shells || echo /bin/startsh >> rootfs/etc/shells
cp "$KIT/nodes.txt" nodes.txt

# 3a. Install a useful toolset in the x86 rootfs. A static apk-tools binary
# lets this work on non-Alpine build hosts without requiring 32-bit execution.
if command -v apk >/dev/null 2>&1; then
  APK=$(command -v apk)
else
  case $(uname -m) in
    x86_64) APK_HOST_ARCH=x86_64 ;;
    aarch64) APK_HOST_ARCH=aarch64 ;;
    *) echo "Unsupported host architecture for apk-tools-static: $(uname -m)" >&2; exit 1 ;;
  esac
  APK="$W/apk.static"
  if [ ! -x "$APK" ]; then
    APK_REPO=https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main/$APK_HOST_ARCH
    APK_VERSION=$(curl -fsSL "$APK_REPO/APKINDEX.tar.gz" | tar -xzOf - APKINDEX | awk '/^P:apk-tools-static$/{found=1} found && /^V:/{sub(/^V:/, ""); print; found=0}')
    [ -n "$APK_VERSION" ] || { echo "Could not find apk-tools-static for $APK_HOST_ARCH" >&2; exit 1; }
    APK_FILE=apk-tools-static-$APK_VERSION.apk
    mkdir -p apk-static
    curl -fsSL -o apk-tools-static.apk "$APK_REPO/$APK_FILE"
    tar -xzf apk-tools-static.apk -C apk-static sbin/apk.static
    cp apk-static/sbin/apk.static "$APK"
    chmod +x "$APK"
  fi
fi
printf '%s\n' \
  "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main" \
  "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/community" > repositories
read -r -a APK_PACKAGE_LIST <<< "$APK_PACKAGES"
"$APK" --root "$W/rootfs" --arch x86 --repositories-file "$W/repositories" --no-cache add "${APK_PACKAGE_LIST[@]}"
install -Dm644 repositories rootfs/etc/apk/repositories

# 4. kernel with rootfs embedded as initramfs  (edit with: make -C work/linux ARCH=i386 menuconfig)
if [ ! -d linux ]; then
  curl -fsSL https://codeload.github.com/torvalds/linux/tar.gz/refs/tags/$KERNEL_TAG | tar xz; mv linux-${KERNEL_TAG#v} linux
fi
cd linux
if [ ! -f .config ]; then make ARCH=i386 tinyconfig >/dev/null; fi
sed "s#@ROOTFS@#$W/rootfs#; s#@NODES@#$W/nodes.txt#" "$KIT/frag.cfg" >> .config
make ARCH=i386 olddefconfig >/dev/null
make ARCH=i386 -j"$JOBS" bzImage
cd ..

# 5. single HTML
cp package/build/libv86.js libv86.js
cd "$KIT" && python3 assemble.py "$W/libv86.js" "$W/package/build/v86.wasm" "$W/seabios.bin" "$W/vgabios.bin" "$W/linux/arch/x86/boot/bzImage" "$KIT/linux.html"
