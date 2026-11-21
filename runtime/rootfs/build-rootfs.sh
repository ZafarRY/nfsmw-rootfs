#!/usr/bin/env bash
# Membuat rootfs arm64 (Debian) berisi Box64 + Wine WoW64 (x86_64) + DXVK.
# Jalankan sebagai root di host ARM64 (mis. runner GitHub ubuntu-24.04-arm).
# BELUM DIUJI: cek versi dan URL di bawah sebelum dipakai.
set -euo pipefail

SUITE="${SUITE:-bookworm}"
OUT="${OUT:-$PWD/out}"
ROOT="$OUT/rootfs"

BOX64_REF="${BOX64_REF:?isi tag/commit Box64, mis. v0.3.x}"
WINE_VER="${WINE_VER:?isi versi Wine WoW64, mis. 9.x}"
DXVK_VER="${DXVK_VER:?isi versi DXVK, mis. 2.x}"

WINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VER}/wine-${WINE_VER}-amd64-wow64.tar.xz"
DXVK_URL="https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VER}/dxvk-${DXVK_VER}.tar.gz"

[ "$(id -u)" = 0 ] || { echo "Harus root"; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "Host harus arm64"; exit 1; }

mkdir -p "$OUT"
rm -rf "$ROOT"

echo "== 1. Base system arm64 =="
debootstrap --arch=arm64 --variant=minbase \
  --include=ca-certificates,libstdc++6,libgcc-s1,zlib1g,libfreetype6,libx11-6,libxext6,libasound2,libpulse0,libvulkan1,mesa-vulkan-drivers,libgl1 \
  "$SUITE" "$ROOT" http://deb.debian.org/debian

mount --bind /dev  "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
trap 'umount -l "$ROOT/dev" "$ROOT/proc" 2>/dev/null || true' EXIT

echo "== 2. Build Box64 (dynarec) =="
chroot "$ROOT" /bin/bash -euxc "
  apt-get update
  apt-get install -y --no-install-recommends build-essential cmake git python3
  git clone https://github.com/ptitSeb/box64 /tmp/box64
  cd /tmp/box64 && git checkout '$BOX64_REF'
  cmake -B build -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
  cmake --build build -j\$(nproc)
  cmake --install build
  apt-get purge -y build-essential cmake git python3
  apt-get autoremove -y
  rm -rf /tmp/box64
"

echo "== 3. Library x86_64 untuk Box64 (bagian paling mungkin perlu penyesuaian) =="
chroot "$ROOT" /bin/bash -euxc "
  dpkg --add-architecture amd64
  apt-get update
  mkdir -p /tmp/x86 /usr/lib/box64-x86_64-linux-gnu
  cd /tmp/x86
  apt-get download libc6:amd64 libstdc++6:amd64 libgcc-s1:amd64 zlib1g:amd64 \
    libfreetype6:amd64 libx11-6:amd64 libxext6:amd64
  for d in *.deb; do dpkg-deb -x \"\$d\" ex; done
  cp -a ex/lib/x86_64-linux-gnu/. /usr/lib/box64-x86_64-linux-gnu/ || true
  cp -a ex/usr/lib/x86_64-linux-gnu/. /usr/lib/box64-x86_64-linux-gnu/ || true
  rm -rf /tmp/x86
"

echo "== 4. Wine WoW64 (x86_64, dijalankan lewat Box64) =="
mkdir -p "$ROOT/opt/wine"
curl -fL "$WINE_URL" | tar -xJ -C "$ROOT/opt/wine" --strip-components=1

echo "== 5. DXVK (D3D9 untuk speed.exe 32-bit: ambil x32) =="
mkdir -p "$ROOT/opt/dxvk"
curl -fL "$DXVK_URL" | tar -xz -C "$ROOT/opt/dxvk" --strip-components=1

echo "== 6. Bersihkan dan kemas =="
chroot "$ROOT" /bin/bash -c "apt-get clean; rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man"
umount -l "$ROOT/dev" "$ROOT/proc"
trap - EXIT
tar -C "$ROOT" -cJf "$OUT/rootfs-arm64.tar.xz" .
sha256sum "$OUT/rootfs-arm64.tar.xz" | tee "$OUT/rootfs-arm64.tar.xz.sha256"
ls -lh "$OUT/rootfs-arm64.tar.xz"
