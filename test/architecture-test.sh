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

arm_kernel_stage_mode=$(
  OMARCHY_ARCH=aarch64
  declare -A file_permissions
  source "$ROOT/configs/profiledef.sh"
  printf '%s\n' "${file_permissions[/usr/local/bin/omarchy-iso-stage-arm64-kernel]:-}"
)
assert_equal "$arm_kernel_stage_mode" "0:0:755" \
  "aarch64 profile declares the live-kernel staging executable"

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

local_package_map="$ROOT/builder/omarchy-aarch64-local-packages"
awk '
  /^[[:space:]]*#/ || NF == 0 { next }
  NF != 3 { exit 1 }
  $3 != "syncdeps" && $3 != "nodeps" { exit 1 }
  { print $1 "\t" $2 "\t" $3 }
' "$local_package_map" > "$test_tmp/local-package-map" ||
  fail "AArch64 local package map rows are valid"
pass "AArch64 local package map rows are valid"

expected_local_targets=$'aether\nasdcontrol\ncliamp\ndotnet-runtime\nhyprland-preview-share-picker\nlimine-mkinitcpio-hook\nlimine-snapper-sync\nlocalsend\nmise\nobs-studio\nobsidian\nomacut\nomarchy-dev\nomarchy-keyring\nomarchy-nvim\nomarchy-settings-dev\nomawrite\npinta\npython-terminaltexteffects\nquickshell-git\ntensaku\ntobi-try\nttf-ia-writer\nttf-jetbrains-mono-nerd-basic\ntzupdate\nufw-docker\nxdg-terminal-exec\nyaru-icon-theme\nyay'
actual_local_targets=$(
  awk -F '\t' '$1 != "-" { print $1 }' "$test_tmp/local-package-map" | sort -u
)
assert_equal "$actual_local_targets" "$expected_local_targets" \
  "AArch64 local package map covers the fresh-image repository gaps"

assert_equal "$(
  awk -F '\t' '$1 == "-" { print $2 ":" $3 }' "$test_tmp/local-package-map"
)" "gradle:syncdeps" "Gradle remains build-only"
assert_equal "$(
  awk -F '\t' '$1 == "dotnet-runtime" { print $2 }' "$test_tmp/local-package-map"
)" "dotnet-sdk-bin" "the .NET runtime target selects its ARM provider"
assert_equal "$(
  awk -F '\t' '$1 == "mise" { print $2 }' "$test_tmp/local-package-map"
)" "mise-bin" "the mise target selects its ARM provider"
assert_equal "$(
  awk -F '\t' '$1 == "obsidian" { print $2 }' "$test_tmp/local-package-map"
)" "obsidian-appimage" "the Obsidian target selects its ARM provider"

if [[ -n ${OMARCHY_PKGS_PATH:-} ]]; then
  while IFS=$'\t' read -r target package dependency_mode; do
    pkgbuild_dir="$OMARCHY_PKGS_PATH/pkgbuilds/$package"
    [[ -f $pkgbuild_dir/PKGBUILD ]] ||
      fail "mapped package source exists for $package"

    srcinfo=$(cd "$pkgbuild_dir" && makepkg --printsrcinfo)
    if ! grep -Eq '^[[:space:]]+arch = (any|aarch64)$' <<< "$srcinfo"; then
      fail "$package supports aarch64"
    fi

    if [[ $target != "-" ]]; then
      if ! awk -F ' = ' -v target="$target" '
        /^[[:space:]]*(pkgname|provides) = / {
          value=$2
          sub(/[<>=].*$/, "", value)
          if (value == target) found=1
        }
        END { exit !found }
      ' <<< "$srcinfo"; then
        fail "$package satisfies $target"
      fi
    fi
  done < "$test_tmp/local-package-map"
  pass "mapped package recipes support AArch64 and satisfy their targets"
fi

grep -q -- '--packages-only' "$ROOT/bin/omarchy-iso-make" ||
  fail "package-only closure mode is exposed by the build entrypoint"
grep -q 'OMARCHY_PACKAGES_ONLY' "$ROOT/builder/build-iso.sh" ||
  fail "package-only closure mode stops before mkarchiso"
pass "package-only closure mode is wired through the ISO builder"

grep -Fq 'build_dependency_cache_dir="$build_cache_dir/airootfs/var/cache/omarchy/build-dependencies"' \
  "$ROOT/builder/build-iso.sh" ||
  fail "build-only package archives persist across container retries"
grep -q 'ln -sfn "$package_file" "$staged_file"' \
  "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "temporary package repository stages archives beside its database"
grep -q 'LC_ALL=C sort -z' "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "build dependency fingerprints are locale independent"
grep -q 'makepkg_flags="--syncdeps --rmdeps ' \
  "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "transient build dependencies are removed between package builds"
grep -q 'Reusing cached runtime package' \
  "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "completed runtime packages persist across closure retries"
grep -q 'safe.directory=/omarchy-source' \
  "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "source-backed package fingerprints trust the mounted checkout explicitly"
grep -q 'rm -f "/var/cache/pacman/pkg/$(basename "$package_file")"' \
  "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "stale local archives are evicted from pacman's package cache"
grep -q "name 'omarchy-keyring-\\*.pkg.tar.\\*'" "$ROOT/builder/build-iso.sh" ||
  fail "local keyring discovery accepts Arch Linux ARM package compression"
pass "AArch64 build dependencies remain usable across package boundaries and retries"
