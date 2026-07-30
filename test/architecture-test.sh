#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
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
pass "unsupported architectures are rejected"

assert_equal "$(omarchy_iso_docker_image aarch64)" "menci/archlinuxarm:latest" \
  "aarch64 selects the Arch Linux ARM container"
assert_equal "$(omarchy_iso_node_architecture aarch64)" "arm64" \
  "aarch64 selects the Node.js arm64 archive"
assert_equal "$(omarchy_iso_live_kernel aarch64)" "linux-aarch64" \
  "aarch64 selects the validated Arch Linux ARM kernel"

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
  aarch64 \
  "$test_tmp/packages" \
  "$test_tmp/packages.aarch64" \
  "$test_tmp/excludes"

expected=$'# fixture\nlinux-aarch64\nlinux-aarch64-headers\nqemu-user-binfmt\nkeep-me'
actual=$(< "$test_tmp/packages.aarch64")
assert_equal "$actual" "$expected" "aarch64 package substitutions and exclusions are exact"

profile=$(
  OMARCHY_ARCH=aarch64
  declare -A file_permissions
  source "$ROOT/configs/profiledef.sh"
  printf '%s|%s\n' "$arch" "${bootmodes[*]}"
)
assert_equal "$profile" "aarch64|uefi.grub" "aarch64 profile is UEFI-only"

PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH="$ROOT/configs/airootfs/usr/share/omarchy-iso" \
  python - <<'PY'
from orchestrator.architecture import limine_efi_names

assert limine_efi_names("x86_64") == ("BOOTX64.EFI", "limine_x64.efi")
assert limine_efi_names("aarch64") == ("BOOTAA64.EFI", "limine_aa64.efi")
PY
pass "Limine EFI source and destination names follow the UEFI architecture"

grep -q "^Target = linux-aarch64$" \
  "$ROOT/configs/airootfs/etc/pacman.d/hooks/99-omarchy-iso-arm64-kernel.hook" ||
  fail "ARM64 live-kernel hook targets linux-aarch64"
grep -q "^ALL_kver='/boot/vmlinuz-linux-aarch64'$" \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/linux-aarch64.preset" ||
  fail "ARM64 archiso preset uses the staged kernel path"
pass "ARM64 live-kernel staging contract is present"

if grep -q '^\[multilib\]$' "$ROOT/configs/pacman-online-aarch64.conf"; then
  fail "aarch64 pacman config excludes multilib"
fi
for repository in core extra alarm aur omarchy; do
  grep -q "^\\[$repository\\]$" "$ROOT/configs/pacman-online-aarch64.conf" ||
    fail "aarch64 pacman config includes $repository"
done
pass "aarch64 pacman config contains only the required repository families"

if grep -Eq 'repo-add .*\\*\\.pkg\\.tar\\.zst' "$ROOT/builder/build-iso.sh"; then
  fail "offline repository indexing accepts Arch Linux ARM package compression"
fi
grep -q "name '\\*.pkg.tar.\\*'" "$ROOT/builder/build-iso.sh" ||
  fail "offline repository indexing discovers every package archive format"
pass "offline repository indexing accepts xz and zstd package archives"
