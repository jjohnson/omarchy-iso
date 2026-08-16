"""Architecture-sensitive target boot finalization tests."""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class AArch64InstallerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "target"
        self.boot = self.target / "boot"
        self.boot.mkdir(parents=True)
        self.ctx = types.SimpleNamespace(target=self.target)

    def write(self, relative: str, text: str = "fixture\n") -> Path:
        path = self.target / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_limine_install_maps_aarch64_source_and_target_names(self):
        self.write("usr/share/limine/BOOTAA64.EFI", "efi")

        with (
            mock.patch.object(
                phases_impl,
                "limine_efi_names",
                return_value=("BOOTAA64.EFI", "limine_aa64.efi"),
            ),
            mock.patch.object(phases_impl, "_write_limine_pacman_hook") as write_hook,
            mock.patch.object(phases_impl, "_register_limine_efi_entry"),
        ):
            phases_impl._install_limine_efi(
                self.ctx,
                esp_mount="/boot",
                disk=Path("/dev/vda"),
                part=1,
            )

        installed = self.target / "boot/EFI/limine/limine_aa64.efi"
        self.assertEqual(installed.read_text(), "efi")
        self.assertIn("BOOTAA64.EFI", write_hook.call_args.args[1])

    def test_native_limine_entry_requires_assets_and_update_hook(self):
        self.write("boot/Image", "kernel")
        self.write("boot/initramfs-linux.img", "initramfs")
        self.write(
            "etc/pacman.d/hooks/99-omarchy-aarch64-kernel.hook",
            "Exec = /usr/bin/omarchy-update-kernel-aarch64\n",
        )
        config = """
/Omarchy
    protocol: linux
    path: boot():/Image
    module_path: boot():/initramfs-linux.img
"""

        phases_impl._validate_aarch64_limine_entry(self.ctx, self.boot, config)

    def test_finalizer_invokes_aarch64_updater_after_dropins(self):
        self.write("usr/bin/omarchy-update-kernel-aarch64")
        self.write(
            "etc/default/limine",
            'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+=" root=UUID=root"\n',
        )
        self.write("etc/snapper/configs/root")
        self.write("boot/limine.conf", "/Omarchy\n")

        with (
            mock.patch.object(phases_impl, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl.subprocess, "run") as run,
        ):
            phases_impl.finalize_limine_boot(self.ctx)

        self.assertEqual(
            run.call_args_list[0].args[0],
            ["arch-chroot", str(self.target), "omarchy-update-kernel-aarch64"],
        )


if __name__ == "__main__":
    unittest.main()
