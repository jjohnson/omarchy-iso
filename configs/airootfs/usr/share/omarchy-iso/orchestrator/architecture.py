"""Architecture-specific names shared by the installer boot path."""

from __future__ import annotations

import platform
import re


def machine(value: str | None = None) -> str:
    detected = value or platform.machine()
    return "aarch64" if detected == "arm64" else detected


def limine_efi_names(value: str | None = None) -> tuple[str, str]:
    match machine(value):
        case "x86_64":
            return "BOOTX64.EFI", "limine_x64.efi"
        case "aarch64":
            return "BOOTAA64.EFI", "limine_aa64.efi"
        case architecture:
            raise RuntimeError(f"Unsupported Limine EFI architecture: {architecture}")


def node_archive_architecture(value: str | None = None) -> str:
    match machine(value):
        case "x86_64":
            return "x64"
        case "aarch64":
            return "arm64"
        case architecture:
            raise RuntimeError(f"Unsupported Node.js architecture: {architecture}")


def limine_linux_boot_assets(config_text: str) -> dict[str, list[str]]:
    """Return ESP-relative assets from native Limine Linux entries."""
    if not re.search(r"^\s*protocol:\s+linux\s*$", config_text, re.MULTILINE):
        return {}

    assets: dict[str, list[str]] = {}
    for key, config_keys in (
        ("kernel_path", ("kernel_path", "path")),
        ("module_path", ("module_path",)),
    ):
        key_pattern = "|".join(re.escape(config_key) for config_key in config_keys)
        matches = re.findall(
            rf"^\s*(?:{key_pattern}):\s+boot\(\):/([^#\s]+)(?:#[^\s]+)?\s*$",
            config_text,
            re.MULTILINE,
        )
        if matches:
            assets[key] = matches
    return assets
