#!/usr/bin/env python3
"""Create a branded Finder disk image, without scripting or launching Finder."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import dmgbuild
from ds_store import DSStore
from mac_alias import Bookmark

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--volume", required=True)
parser.add_argument("--icon", type=Path, required=True)
parser.add_argument("--background", type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve(strict=True)
assert not args.output.exists(), "Do not overwrite an existing disk image"
assert (source / "Expertise Typer.app").is_dir(), "Missing renamed app"
settings = {
    "format": "UDZO", "filesystem": "HFS+",
    "files": [str(p) for p in source.iterdir() if not p.is_symlink()],
    "symlinks": {"Applications": "/Applications"},
    "icon": str(args.icon.resolve(strict=True)),
    "background": str(args.background.resolve(strict=True)),
    "window_rect": ((180, 180), (720, 540)),
    "default_view": "icon-view", "include_icon_view_settings": True,
    "show_status_bar": False, "show_toolbar": False, "show_sidebar": False,
    "show_pathbar": False, "show_tab_view": False,
    "icon_size": 92, "text_size": 14, "label_pos": "bottom",
    "icon_locations": {"Expertise Typer.app": (220, 220), "Applications": (500, 220),
                       "Guide and licenses": (360, 432)},
    # Hiding an extension writes FinderInfo on the signed app bundle. Sparkle's
    # strict code-signature verification rejects that extra metadata.
    "hide_extensions": [],
    "arrange_by": None,
}

def target_volume_bookmark(data, background):
    """Keep native target metadata without shipping build-machine/source-image paths."""
    bookmark = Bookmark.from_bytes(data)
    target = bookmark.tocs[0][1]
    # Native bookmarks can include separate TOCs for the build machine's root
    # volume and the temporary source DMG. Finder only needs the mounted target.
    target.pop(0x2000, None)  # Parent-volume TOC path.
    target.pop(0x2040, None)  # Source-image bookmark TOC.
    names, identifiers = target[0x1004], target[0x1005]
    assert names[-1] == background.name and identifiers, "Unexpected native background target"
    target[0x1004] = names[-1:]
    target[0x1005] = identifiers[-1:]
    bookmark.tocs = bookmark.tocs[:1]
    return bookmark


with tempfile.TemporaryDirectory(prefix="expertise-native-bookmark-") as temporary:
    temporary = Path(temporary)
    helper = temporary / "native-background-bookmark"
    subprocess.run(["clang", "-fobjc-arc", "-fmodules", "-framework", "Foundation",
                    str(Path(__file__).with_name("native-background-bookmark.m")),
                    "-o", str(helper)], check=True)
    mounted = []
    validated = []

    def remember_mount(mount_point, options):
        mounted.append(Path(mount_point))

    def finalize_background(event):
        if event.get("type") != "operation::finished" or event.get("operation") != "dsstore::create":
            return
        assert len(mounted) == 1, "Could not identify the installer volume"
        volume = mounted[0]
        backgrounds = [path for path in volume.glob(".background.*") if path.is_file()]
        assert len(backgrounds) == 1, "Missing or ambiguous installer background"
        background = backgrounds[0]
        native = temporary / "native.bookmark"
        portable = temporary / "portable.bookmark"
        subprocess.run([str(helper), "create", str(background), str(native)], check=True)
        bookmark = target_volume_bookmark(native.read_bytes(), background)
        portable.write_bytes(bookmark.to_bytes())
        subprocess.run([str(helper), "validate", str(portable), str(background)], check=True)
        # dmgbuild's legacy synthetic pBBk exists but fails Foundation resolution
        # on current macOS. Replace it after DSStore is closed and before detach;
        # leave the window layout and legacy backgroundImageAlias intact.
        with DSStore.open(str(volume / ".DS_Store"), "r+") as store:
            store["."]["pBBk"] = bookmark
        with DSStore.open(str(volume / ".DS_Store"), "r") as store:
            portable.write_bytes(store["."]["pBBk"].to_bytes())
        subprocess.run([str(helper), "validate", str(portable), str(background)], check=True)
        # Installer decoration must never alter the signed application. Verify
        # after dmgbuild has applied all Finder attributes and layout metadata.
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                        "--all-architectures", str(volume / "Expertise Typer.app")], check=True)
        validated.append(True)

    settings["create_hook"] = remember_mount
    dmgbuild.build_dmg(str(args.output), args.volume, settings=settings, callback=finalize_background)
    if len(validated) != 1:
        raise RuntimeError("Installer background bookmark was not validated")
