"""Finder layout for the Wattline installer. Loaded by dmgbuild."""

from pathlib import Path
import subprocess

app = Path(defines["app"])
format = "UDZO"
filesystem = "HFS+"
compression_level = 9
files = [(str(app), "Wattline.app"), (defines["license"], ".license/LICENSE")]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/Wattline.icns")
background = defines["background"]
window_rect = ((160, 110), (480, 264))
icon_locations = {"Wattline.app": (122, 91), "Applications": (358, 91)}
icon_size = 80
text_size = 13


def create_hook(mount_point, options):
    """Verify the copied payload before dmgbuild detaches its staging volume."""
    root = Path(mount_point)
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
         root / "Wattline.app"],
        check=True,
    )
    if (root / ".license/LICENSE").read_bytes() != Path(defines["license"]).read_bytes():
        raise ValueError("The license in the disk image does not match LICENSE.")
