#!/bin/bash
# Build Omarchy packages from mounted source (/omarchy-source + /omarchy-pkgs)
# and place the resulting package archives in the offline mirror.

set -e

offline_mirror_dir="$1"
if [[ -z $offline_mirror_dir ]]; then
  echo "Usage: build-omarchy-packages.sh <offline-mirror-dir> [build-dependency-cache-dir]" >&2
  exit 1
fi
build_dependency_cache_dir="${2:-$offline_mirror_dir/../../build-dependencies}"

if [[ ! -d /omarchy-source ]]; then
  echo "ERROR: /omarchy-source not mounted (pass --local-source or set OMARCHY_SOURCE_PATH)" >&2
  exit 1
fi
if [[ ! -d /omarchy-pkgs ]]; then
  echo "ERROR: /omarchy-pkgs not mounted (set OMARCHY_PKGS_PATH or place ../omarchy-pkgs)" >&2
  exit 1
fi

work_dir=/tmp/omarchy-pkg-build
rm -rf "$work_dir"
mkdir -p "$work_dir" "$offline_mirror_dir" "$build_dependency_cache_dir"
local_runtime_archives=()

if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-omarchy-pkg-builder
chmod 440 /etc/sudoers.d/99-omarchy-pkg-builder
chown builder:builder "$work_dir"

pacman -Sy --noconfirm

: "${OMARCHY_RUNTIME_PACKAGE:=omarchy-dev}"
: "${OMARCHY_SETTINGS_PACKAGE:=omarchy-settings-dev}"
: "${OMARCHY_NVIM_PACKAGE:=omarchy-nvim}"

package_archive_satisfies() {
  local target="$1"
  local package_file="$2"
  local package_name provided

  package_name=$(pacman -Qp "$package_file" | awk '{print $1}')
  [[ $package_name == "$target" ]] && return 0

  while IFS= read -r provided; do
    provided="${provided#provides = }"
    provided="${provided%%[<>=]*}"
    [[ $provided == "$target" ]] && return 0
  done < <(bsdtar -xOf "$package_file" .PKGINFO | grep '^provides = ' || true)

  return 1
}

package_recipe_fingerprint() {
  local package_source="$1"

  (
    cd "$package_source"
    find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
  )
}

stage_build_repo_archives() {
  local package_file staged_file
  local -a staged_files=()

  for package_file in "$@"; do
    staged_file="$work_dir/$(basename "$package_file")"
    ln -sfn "$package_file" "$staged_file"
    staged_files+=("$staged_file")
  done

  repo-add "$work_dir/omarchy-build.db.tar.gz" "${staged_files[@]}" >/dev/null
  ln -sfn omarchy-build.db.tar.gz "$work_dir/omarchy-build.db"
  pacman -Sy --noconfirm >/dev/null
}

reuse_build_dependency() {
  local package="$1"
  local recipe_fingerprint="$2"
  local fingerprint_file="$build_dependency_cache_dir/$package.recipe.sha256"
  local manifest_file="$build_dependency_cache_dir/$package.archives"
  local archive_name
  local -a package_files=()

  [[ -f $fingerprint_file && -f $manifest_file ]] || return 1
  [[ $(< "$fingerprint_file") == "$recipe_fingerprint" ]] || return 1

  while IFS= read -r archive_name; do
    [[ -n $archive_name ]] || continue
    [[ -f $build_dependency_cache_dir/$archive_name ]] || return 1
    package_files+=("$build_dependency_cache_dir/$archive_name")
  done < "$manifest_file"
  (( ${#package_files[@]} > 0 )) || return 1

  echo "Reusing cached build dependency $package"
  stage_build_repo_archives "${package_files[@]}"
}

persist_build_dependency() {
  local package="$1"
  local recipe_fingerprint="$2"
  shift 2
  local manifest_file="$build_dependency_cache_dir/$package.archives"
  local manifest_tmp="$manifest_file.tmp"
  local package_file archive_name
  local -a cached_files=()

  if [[ -f $manifest_file ]]; then
    while IFS= read -r archive_name; do
      [[ -n $archive_name ]] || continue
      rm -f "$build_dependency_cache_dir/$archive_name"
    done < "$manifest_file"
  fi

  : > "$manifest_tmp"
  for package_file in "$@"; do
    archive_name=$(basename "$package_file")
    cp "$package_file" "$build_dependency_cache_dir/$archive_name"
    printf '%s\n' "$archive_name" >> "$manifest_tmp"
    cached_files+=("$build_dependency_cache_dir/$archive_name")
  done
  mv "$manifest_tmp" "$manifest_file"
  printf '%s\n' "$recipe_fingerprint" \
    > "$build_dependency_cache_dir/$package.recipe.sha256"

  stage_build_repo_archives "${cached_files[@]}"
}

copy_runtime_archives() {
  local target="$1"
  shift
  local package_file package_name
  local satisfied=""

  for package_file in "$@"; do
    if package_archive_satisfies "$target" "$package_file"; then
      satisfied=1
    fi

    package_name=$(pacman -Qp "$package_file" | awk '{print $1}')
    rm -f "$offline_mirror_dir/$package_name-"*.pkg.tar.* \
      "$offline_mirror_dir/$package_name-"*.pkg.tar.*.sig
    cp "$package_file" "$offline_mirror_dir/"
    local_runtime_archives+=("$offline_mirror_dir/$(basename "$package_file")")
  done

  if [[ -z $satisfied ]]; then
    echo "ERROR: built archives do not satisfy fresh-image target $target" >&2
    return 1
  fi
}

build_package() {
  local target="$1"
  local package="$2"
  local dependency_mode="$3"
  local package_work="$work_dir/$package"
  local package_source="$package_work/source"
  local package_destination="$package_work/packages"
  local makepkg_flags recipe_fingerprint package_file
  local -a package_files=()
  local -a persisted_files=()

  echo "----------------------------------------"
  echo "Building $package for ${target:--build-only}"
  echo "----------------------------------------"

  if [[ ! -d /omarchy-pkgs/pkgbuilds/$package ]]; then
    echo "ERROR: package source not found: /omarchy-pkgs/pkgbuilds/$package" >&2
    return 1
  fi

  mkdir -p "$package_source" "$package_destination"
  cp -a "/omarchy-pkgs/pkgbuilds/$package/." "$package_source/"
  chown -R builder:builder "$package_work"
  recipe_fingerprint=$(package_recipe_fingerprint "$package_source")

  if [[ $target == "-" ]] &&
    reuse_build_dependency "$package" "$recipe_fingerprint"; then
    return
  fi

  case "$dependency_mode" in
    syncdeps)
      makepkg_flags="--syncdeps --cleanbuild --force --noconfirm --skippgpcheck"
      ;;
    nodeps)
      makepkg_flags="--cleanbuild --force --noconfirm --skippgpcheck --nodeps"
      ;;
    *)
      echo "ERROR: unsupported dependency mode '$dependency_mode' for $package" >&2
      return 1
      ;;
  esac

  su builder -c "
    cd '$package_source' &&
    PKGDEST='$package_destination' \
    SRCDEST='$work_dir/sources' \
    OMARCHY_SRC=/omarchy-source \
    makepkg $makepkg_flags
  "

  mapfile -d '' package_files < <(
    find "$package_destination" -maxdepth 1 -type f \
      -name '*.pkg.tar.*' ! -name '*.sig' -print0 | sort -z
  )
  if (( ${#package_files[@]} == 0 )); then
    echo "ERROR: $package produced no package archives" >&2
    return 1
  fi

  if [[ $target == "-" ]]; then
    persist_build_dependency "$package" "$recipe_fingerprint" "${package_files[@]}"
  else
    copy_runtime_archives "$target" "${package_files[@]}"
    for package_file in "${package_files[@]}"; do
      persisted_files+=("$offline_mirror_dir/$(basename "$package_file")")
    done
    stage_build_repo_archives "${persisted_files[@]}"
  fi
}

build_aarch64_closure() {
  local package_map=/builder/omarchy-aarch64-local-packages
  local target package dependency_mode extra
  if [[ ! -f $package_map ]]; then
    echo "ERROR: AArch64 local package map not found: $package_map" >&2
    return 1
  fi

  repo-add "$work_dir/omarchy-build.db.tar.gz" >/dev/null
  ln -sfn omarchy-build.db.tar.gz "$work_dir/omarchy-build.db"
  cat >> /etc/pacman.conf <<EOF

[omarchy-build]
SigLevel = Never
Server = file://$work_dir
EOF
  pacman -Sy --noconfirm >/dev/null

  while read -r target package dependency_mode extra; do
    [[ -z $target || $target == \#* ]] && continue
    if [[ -z $package || -z $dependency_mode || -n $extra ]]; then
      echo "ERROR: invalid AArch64 local package row: $target $package $dependency_mode $extra" >&2
      return 1
    fi
    build_package "$target" "$package" "$dependency_mode"
  done < "$package_map"

  if (( ${#local_runtime_archives[@]} == 0 )); then
    echo "ERROR: AArch64 local package closure produced no runtime archives" >&2
    return 1
  fi

  rm -f "$offline_mirror_dir"/omarchy-local.db*
  repo-add "$offline_mirror_dir/omarchy-local.db.tar.gz" \
    "${local_runtime_archives[@]}" >/dev/null
}

build_x86_local_packages() {
  local packages=(
    omarchy-keyring
    "$OMARCHY_SETTINGS_PACKAGE"
    "$OMARCHY_RUNTIME_PACKAGE"
    "$OMARCHY_NVIM_PACKAGE"
  )
  local package package_work package_file destination

  for package in "${packages[@]}"; do
    package_work="$work_dir/$package"
    mkdir -p "$package_work"
    cp -a "/omarchy-pkgs/pkgbuilds/$package/." "$package_work/"
    chown -R builder:builder "$package_work"

    su builder -c "
      cd '$package_work' &&
      PKGDEST='$work_dir' \
      OMARCHY_SRC=/omarchy-source \
      makepkg --noconfirm --skippgpcheck --skipchecksums --nodeps -f
    "
  done

  for package_file in "$work_dir"/*.pkg.tar.*; do
    [[ -f $package_file && $package_file != *.sig ]] || continue
    destination="$offline_mirror_dir/$(basename "$package_file")"
    rm -f "$destination" "$destination.sig"
    mv "$package_file" "$destination"
    local_runtime_archives+=("$destination")
  done

  rm -f "$offline_mirror_dir"/omarchy-local.db*
  repo-add "$offline_mirror_dir/omarchy-local.db.tar.gz" \
    "${local_runtime_archives[@]}" >/dev/null
}

if [[ ${OMARCHY_ARCH:-x86_64} == "aarch64" ]]; then
  build_aarch64_closure
else
  build_x86_local_packages
fi

echo
echo "Built local packages, placed in $offline_mirror_dir:"
find "$offline_mirror_dir" -maxdepth 1 -type f \
  -name '*.pkg.tar.*' ! -name '*.sig' -printf '  %f\n' | sort
