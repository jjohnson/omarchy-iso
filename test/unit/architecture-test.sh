#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/builder/architecture.sh"

fail() {
  echo "not ok - $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  local description="$3"

  [[ $actual == "$expected" ]] || fail "$description (expected '$expected', got '$actual')"
  pass "$description"
}

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

omarchy_iso_validate_architecture x86_64
omarchy_iso_validate_architecture aarch64
if omarchy_iso_validate_architecture riscv64 2>/dev/null; then
  fail "unsupported architectures are rejected"
fi
pass "supported architectures are explicit"

assert_equal "$(omarchy_iso_docker_image aarch64)" "menci/archlinuxarm:latest" \
  "AArch64 selects the Arch Linux ARM container"
assert_equal "$(omarchy_iso_node_architecture aarch64)" "arm64" \
  "AArch64 selects the Node.js arm64 archive"
assert_equal "$(omarchy_iso_live_kernel aarch64)" "linux-aarch64" \
  "AArch64 selects the validated Arch Linux ARM kernel"
assert_equal "$(omarchy_iso_online_pacman_config aarch64 rc)" \
  "/configs/pacman-online-rc-aarch64.conf" \
  "AArch64 selects its channel-specific Pacman config"

cat > "$test_tmp/archiso.conf" <<'MKINITCPIO'
# fixture
HOOKS=(base udev microcode modconf kms memdisk archiso block filesystems)
MKINITCPIO
omarchy_iso_prepare_initramfs_config \
  aarch64 "$test_tmp/archiso.conf" "$test_tmp/archiso-aarch64.conf"
assert_equal "$(<"$test_tmp/archiso-aarch64.conf")" \
  $'# fixture\nHOOKS=(base udev modconf kms archiso block filesystems)' \
  "AArch64 live initramfs excludes x86-only hooks"

cat > "$test_tmp/packages" <<'PACKAGES'
# fixture
amd-ucode
linux
linux-headers
qemu-user-static-binfmt # provider differs on Arch Linux ARM
keep-me
drop-me
PACKAGES
printf '%s\n' drop-me > "$test_tmp/excludes"
omarchy_iso_prepare_package_list \
  aarch64 "$test_tmp/packages" "$test_tmp/packages.aarch64" "$test_tmp/excludes"
assert_equal "$(<"$test_tmp/packages.aarch64")" \
  $'# fixture\nlinux-aarch64\nlinux-aarch64-headers\nqemu-user-binfmt\nkeep-me' \
  "AArch64 package substitutions and exclusions are exact"

profile=$(
  OMARCHY_ARCH=aarch64
  declare -A file_permissions
  source "$ROOT/configs/profiledef.sh"
  printf '%s|%s|%s\n' "$arch" "${bootmodes[*]}" "${airootfs_image_tool_options[*]}"
)
assert_equal "$profile" \
  "aarch64|uefi.grub|-comp xz -b 1M -action uncompressed@subpathname(var/cache/omarchy/mirror/offline)" \
  "AArch64 profile is UEFI-only and uses kernel-supported XZ"

profile=$(
  OMARCHY_ARCH=x86_64
  declare -A file_permissions
  source "$ROOT/configs/profiledef.sh"
  printf '%s|%s|%s\n' "$arch" "${bootmodes[*]}" "${airootfs_image_tool_options[*]}"
)
assert_equal "$profile" \
  "x86_64|bios.syslinux uefi.grub|-comp zstd -Xcompression-level 19 -b 1M -action uncompressed@subpathname(var/cache/omarchy/mirror/offline)" \
  "x86_64 profile behavior remains unchanged"

cp "$ROOT/archiso/archiso/mkarchiso" "$test_tmp/mkarchiso"
patch --silent "$test_tmp/mkarchiso" "$ROOT/builder/mkarchiso-aarch64.patch" ||
  fail "AArch64 compatibility patch applies to pinned Archiso"
bash -O extglob -n "$test_tmp/mkarchiso"
pass "AArch64 GRUB module filtering applies to pinned Archiso"

for config in "$ROOT"/configs/pacman-online-*-aarch64.conf; do
  if grep -q '^\[multilib\]$\|^\[arch-mact2\]$' "$config"; then
    fail "$(basename "$config") contains an x86-only repository"
  fi
  for repository in core extra alarm aur omarchy; do
    grep -q "^\[$repository\]$" "$config" ||
      fail "$(basename "$config") includes $repository"
  done
done
pass "AArch64 Pacman configs contain the required repository families"

grep -q "name '\*.pkg.tar.\*'" "$ROOT/builder/build-iso.sh" ||
  fail "offline repository indexing accepts every package compression"
if grep -q 'sudo rm -rf /var/cache/pacman/pkg' "$ROOT/bin/omarchy-iso-make"; then
  fail "ISO builds do not clear the host package cache"
fi
grep -q 'iso_${OMARCHY_MIRROR}_${OMARCHY_ARCH}' "$ROOT/bin/omarchy-iso-make" ||
  fail "ISO build cache is isolated by channel and architecture"
pass "build caches and package archive discovery are architecture-safe"

grep -q '^Target = linux-aarch64$' \
  "$ROOT/configs/airootfs/etc/pacman.d/hooks/99-omarchy-iso-aarch64-kernel.hook" ||
  fail "live kernel hook targets linux-aarch64"
grep -q "^ALL_kver='/boot/vmlinuz-linux-aarch64'$" \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/linux-aarch64.preset" ||
  fail "Archiso preset uses the staged AArch64 kernel"
pass "AArch64 live-kernel staging contract is present"
