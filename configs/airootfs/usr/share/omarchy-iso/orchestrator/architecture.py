"""Architecture-specific names shared by the installer boot path."""

from __future__ import annotations

import platform


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
