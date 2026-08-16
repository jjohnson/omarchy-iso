#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

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

local_package_map="$ROOT/builder/omarchy-aarch64-local-packages"
awk '
  /^[[:space:]]*#/ || NF == 0 { next }
  NF != 3 { exit 1 }
  $3 != "syncdeps" && $3 != "nodeps" { exit 1 }
  { print $1 "\t" $2 "\t" $3 }
' "$local_package_map" > "$test_tmp/local-package-map" ||
  fail "AArch64 local package map rows are valid"
pass "AArch64 local package map rows are valid"

expected_local_targets=$'@nvim@\n@runtime@\n@settings@\naether\nasdcontrol\ncliamp\ndotnet-runtime\nherdr\nhyprland-preview-share-picker\nlimine-mkinitcpio-hook\nlimine-snapper-sync\nlocalsend\nmise\nobs-studio\nobsidian\nomacalc\nomacut\nomarchy-keyring\nomawrite\npinta\nquickshell-git\ntensaku\ntobi-try\nttf-ia-writer\nttf-jetbrains-mono-nerd-basic\nttfx\ntzupdate\nufw-docker\nxdg-terminal-exec\nyaru-icon-theme\nyay'
actual_local_targets=$(
  awk -F '\t' '$1 != "-" { print $1 }' "$test_tmp/local-package-map" | sort -u
)
assert_equal "$actual_local_targets" "$expected_local_targets" \
  "AArch64 local map covers all 31 fresh-image repository gaps"

assert_equal "$(
  awk -F '\t' '$1 == "-" { print $2 ":" $3 }' "$test_tmp/local-package-map"
)" "gradle:syncdeps" "Gradle remains build-only"
assert_equal "$(
  awk -F '\t' '$1 == "dotnet-runtime" { print $2 }' "$test_tmp/local-package-map"
)" "dotnet-sdk-bin" "the .NET runtime selects its AArch64 provider"
assert_equal "$(
  awk -F '\t' '$1 == "mise" { print $2 }' "$test_tmp/local-package-map"
)" "mise-bin" "mise selects its AArch64 provider"
assert_equal "$(
  awk -F '\t' '$1 == "obsidian" { print $2 }' "$test_tmp/local-package-map"
)" "obsidian-appimage" "Obsidian selects its AArch64 provider"

if [[ -n ${OMARCHY_PKGS_PATH:-} ]]; then
  while IFS=$'\t' read -r target package dependency_mode; do
    case "$target" in
      @runtime@) target=omarchy-dev ;;
      @settings@) target=omarchy-settings-dev ;;
      @nvim@) target=omarchy-nvim ;;
    esac
    case "$package" in
      @runtime@) package=omarchy-dev ;;
      @settings@) package=omarchy-settings-dev ;;
      @nvim@) package=omarchy-nvim ;;
    esac

    pkgbuild_dir="$OMARCHY_PKGS_PATH/pkgbuilds/$package"
    [[ -f $pkgbuild_dir/PKGBUILD ]] || fail "mapped package source exists for $package"
    srcinfo=$(cd "$pkgbuild_dir" && makepkg --printsrcinfo)
    grep -Eq '^[[:space:]]+arch = (any|aarch64)$' <<< "$srcinfo" ||
      fail "$package supports AArch64"

    if [[ $target != "-" ]]; then
      awk -F ' = ' -v target="$target" '
        /^[[:space:]]*(pkgname|provides) = / {
          value=$2
          sub(/[<>=].*$/, "", value)
          if (value == target) found=1
        }
        END { exit !found }
      ' <<< "$srcinfo" || fail "$package satisfies $target"
    fi
  done < "$test_tmp/local-package-map"
  pass "mapped recipes support AArch64 and satisfy their targets"
fi

grep -q -- '--packages-only' "$ROOT/bin/omarchy-iso-make" ||
  fail "package-only closure mode is exposed"
grep -q 'OMARCHY_PACKAGES_ONLY' "$ROOT/builder/build-iso.sh" ||
  fail "package-only closure mode stops before Archiso"
grep -q 'build_dependency_cache_dir=' "$ROOT/builder/build-iso.sh" ||
  fail "build-only packages use the persistent architecture cache"
grep -q 'Reusing cached runtime package' "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "completed runtime packages can be reused"
grep -q 'unrelated sibling is no longer cached' \
  "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "pruned split-package siblings do not invalidate the runtime cache"
grep -q "find . -path './.git' -prune" "$ROOT/builder/build-omarchy-packages.sh" ||
  fail "mounted linked worktrees have a source fingerprint fallback"
grep -q -- '--git-common-dir' "$ROOT/bin/omarchy-iso-make" ||
  fail "linked worktree Git history is mounted for package pkgver functions"
pass "local closure builds are resumable and independently testable"
