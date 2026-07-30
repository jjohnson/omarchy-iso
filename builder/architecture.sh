#!/bin/bash

omarchy_iso_validate_architecture() {
  local architecture="$1"

  case "$architecture" in
    x86_64|aarch64)
      ;;
    *)
      echo "Error: unsupported ISO architecture '$architecture' (expected x86_64 or aarch64)" >&2
      return 1
      ;;
  esac
}

omarchy_iso_docker_image() {
  local architecture="$1"

  case "$architecture" in
    x86_64)
      echo "archlinux/archlinux:latest"
      ;;
    aarch64)
      echo "menci/archlinuxarm:latest"
      ;;
  esac
}

omarchy_iso_docker_platform() {
  local architecture="$1"

  case "$architecture" in
    x86_64)
      echo "linux/amd64"
      ;;
    aarch64)
      echo "linux/arm64"
      ;;
  esac
}

omarchy_iso_node_architecture() {
  local architecture="$1"

  case "$architecture" in
    x86_64)
      echo "x64"
      ;;
    aarch64)
      echo "arm64"
      ;;
  esac
}

omarchy_iso_live_kernel() {
  local architecture="$1"

  case "$architecture" in
    x86_64)
      echo "linux-t2"
      ;;
    aarch64)
      echo "linux-aarch64"
      ;;
  esac
}

omarchy_iso_prepare_package_list() {
  local architecture="$1"
  local source="$2"
  local destination="$3"
  local excludes="${4:-}"
  local line package

  if [[ $architecture == "x86_64" ]]; then
    cp "$source" "$destination"
    return
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    package="${line%%#*}"
    package="${package#"${package%%[![:space:]]*}"}"
    package="${package%"${package##*[![:space:]]}"}"

    if [[ -z $package ]]; then
      printf '%s\n' "$line"
      continue
    fi

    if [[ -n $excludes ]] && grep -qxF "$package" "$excludes"; then
      continue
    fi

    case "$package" in
      amd-ucode|intel-ucode)
        continue
        ;;
      linux)
        package=linux-aarch64
        ;;
      linux-headers)
        package=linux-aarch64-headers
        ;;
      qemu-user-static-binfmt)
        package=qemu-user-binfmt
        ;;
    esac

    printf '%s\n' "$package"
  done < "$source" > "$destination"
}
