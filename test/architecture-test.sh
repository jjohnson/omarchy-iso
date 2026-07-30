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

cat > "$test_tmp/archiso.conf" <<'MKINITCPIO'
# fixture
HOOKS=(base udev microcode modconf kms memdisk archiso block filesystems)
MKINITCPIO
omarchy_iso_prepare_initramfs_config \
  aarch64 \
  "$test_tmp/archiso.conf" \
  "$test_tmp/archiso-aarch64.conf"
expected=$'# fixture\nHOOKS=(base udev modconf kms archiso block filesystems)'
actual=$(< "$test_tmp/archiso-aarch64.conf")
assert_equal "$actual" "$expected" \
  "aarch64 live initramfs excludes x86-only microcode and memdisk hooks"

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

arm_squashfs_options=$(
  OMARCHY_ARCH=aarch64
  declare -A file_permissions
  source "$ROOT/configs/profiledef.sh"
  printf '%s\n' "${airootfs_image_tool_options[*]}"
)
assert_equal \
  "$arm_squashfs_options" \
  "-comp xz -b 1M -action uncompressed@subpathname(var/cache/omarchy/mirror/offline)" \
  "aarch64 live root uses kernel-supported SquashFS compression"

x86_squashfs_options=$(
  OMARCHY_ARCH=x86_64
  declare -A file_permissions
  source "$ROOT/configs/profiledef.sh"
  printf '%s\n' "${airootfs_image_tool_options[*]}"
)
assert_equal \
  "$x86_squashfs_options" \
  "-comp zstd -Xcompression-level 19 -b 1M -action uncompressed@subpathname(var/cache/omarchy/mirror/offline)" \
  "x86_64 live root retains SquashFS zstd compression"

console_map_tmp="$test_tmp/console-map"
mkdir -p "$console_map_tmp/sysfs/fb0" "$console_map_tmp/sysfs/fb3"
printf '%s\n' "EFI VGA" > "$console_map_tmp/sysfs/fb0/name"
printf '%s\n' "virtio_gpudrmfb" > "$console_map_tmp/sysfs/fb3/name"
cat > "$console_map_tmp/con2fbmap" <<'MAP'
#!/bin/bash
printf '%s\n' "$*" > "$OMARCHY_CONSOLE_MAP_LOG"
MAP
chmod +x "$console_map_tmp/con2fbmap"
OMARCHY_GRAPHICS_SYSFS="$console_map_tmp/sysfs" \
OMARCHY_CONSOLE_MAP_COMMAND="$console_map_tmp/con2fbmap" \
OMARCHY_CONSOLE_MAP_LOG="$console_map_tmp/map.log" \
  "$ROOT/configs/airootfs/usr/local/bin/omarchy-live-console-map"
assert_equal "$(<"$console_map_tmp/map.log")" "1 3" \
  "live console follows the VirtIO framebuffer shown by VM viewers"

console_no_map_tmp="$test_tmp/console-no-map"
mkdir -p "$console_no_map_tmp/sysfs/fb0"
printf '%s\n' "EFI VGA" > "$console_no_map_tmp/sysfs/fb0/name"
OMARCHY_GRAPHICS_SYSFS="$console_no_map_tmp/sysfs" \
OMARCHY_CONSOLE_MAP_COMMAND="$console_map_tmp/con2fbmap" \
OMARCHY_CONSOLE_MAP_LOG="$console_no_map_tmp/map.log" \
  "$ROOT/configs/airootfs/usr/local/bin/omarchy-live-console-map"
[[ ! -e $console_no_map_tmp/map.log ]] ||
  fail "physical framebuffer unexpectedly triggers VM console mapping"
pass "physical framebuffer leaves the live console mapping unchanged"

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
from orchestrator.architecture import limine_efi_names, limine_linux_boot_assets

assert limine_efi_names("x86_64") == ("BOOTX64.EFI", "limine_x64.efi")
assert limine_efi_names("aarch64") == ("BOOTAA64.EFI", "limine_aa64.efi")

config = """
  protocol: linux
  path: boot():/machine/linux-aarch64/Image#kernelhash
  module_path: boot():/machine/linux-aarch64/initramfs-linux.img#initramfshash
"""
assert limine_linux_boot_assets(config) == {
    "kernel_path": ["machine/linux-aarch64/Image"],
    "module_path": ["machine/linux-aarch64/initramfs-linux.img"],
}
PY
pass "Limine EFI names and native ARM64 boot assets follow the UEFI architecture"

grep -q 'machine() == "aarch64"' \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py" ||
  fail "ARM64 installed systems use their native kernel updater"
grep -q 'omarchy-update-kernel-arm64' \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py" ||
  fail "ARM64 installed systems invoke the Omarchy kernel updater"
pass "ARM64 installed boot finalization bypasses the x86-only UKI discovery path"

grep -q 'offline_pacman=True' \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py" ||
  fail "only system finalization prepares the target offline package repository"
pass "resumed user finalization preserves the target online package configuration"

grep -q "^Target = linux-aarch64$" \
  "$ROOT/configs/airootfs/etc/pacman.d/hooks/99-omarchy-iso-arm64-kernel.hook" ||
  fail "ARM64 live-kernel hook targets linux-aarch64"
grep -q "^ALL_kver='/boot/vmlinuz-linux-aarch64'$" \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/linux-aarch64.preset" ||
  fail "ARM64 archiso preset uses the staged kernel path"
pass "ARM64 live-kernel staging contract is present"

cp "$ROOT/archiso/archiso/mkarchiso" "$test_tmp/mkarchiso"
patch --silent "$test_tmp/mkarchiso" "$ROOT/builder/mkarchiso-aarch64.patch" ||
  fail "AArch64 mkarchiso compatibility patch applies to the pinned source"
grep -Fq 'available_grubmodules+=("$module")' "$test_tmp/mkarchiso" ||
  fail "AArch64 mkarchiso filters unavailable GRUB modules"
grep -Fq 'patch --silent "$MKARCHISO" /builder/mkarchiso-aarch64.patch' \
  "$ROOT/builder/build-iso.sh" ||
  fail "AArch64 builder applies the GRUB module compatibility patch"
pass "AArch64 GRUB module filtering applies to the pinned Archiso source"

grep -Fq 'etc/mkinitcpio.d/linux.preset' "$ROOT/builder/build-iso.sh" ||
  fail "AArch64 profile removes releng's stock-kernel preset"
grep -Fq '90-mkinitcpio-install.hook' "$ROOT/builder/build-iso.sh" ||
  fail "AArch64 profile masks the normal host initramfs hook"
grep -Fq 'rm -f /etc/pacman.d/hooks/90-mkinitcpio-install.hook' \
  "$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-stage-arm64-kernel" ||
  fail "AArch64 kernel staging restores the live environment's package hook"
grep -Fq '# remove from airootfs!' \
  "$ROOT/configs/airootfs/etc/pacman.d/hooks/99-omarchy-iso-arm64-kernel.hook" ||
  fail "AArch64 build-only kernel hook is removed from the live environment"
pass "AArch64 package transaction builds only the Archiso initramfs"

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

if grep -q 'sudo rm -rf /var/cache/pacman/pkg' "$ROOT/bin/omarchy-iso-make"; then
  fail "ISO builds do not clear the host pacman cache"
fi
grep -q 'ISO_BUILD_CACHE_DIR="$HOME/.cache/omarchy/iso_${OMARCHY_MIRROR}_${OMARCHY_ARCH}"' \
  "$ROOT/bin/omarchy-iso-make" ||
  fail "ISO build cache is isolated by channel and architecture"
grep -q 'CONTAINER_PACMAN_CACHE_DIR="$ISO_BUILD_CACHE_DIR/pacman/pkg"' \
  "$ROOT/bin/omarchy-iso-make" ||
  fail "container pacman cache stays under the isolated build cache"
grep -q 'CONTAINER_PACMAN_CACHE_DIR:/var/cache/pacman/pkg' \
  "$ROOT/bin/omarchy-iso-make" ||
  fail "container uses the isolated pacman package cache"
pass "ISO builds leave the host pacman cache untouched"

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
