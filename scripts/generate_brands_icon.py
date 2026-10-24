#!/usr/bin/env python3
"""Regenerate the brand icon set shipped with this integration.

Home Assistant shows the default puzzle-piece icon until brand images
exist for the domain (issue #84). Since HA 2026.3 a custom integration
can ship them itself in a ``brand/`` folder, which the brands proxy API
serves in preference to the brands CDN -- no PR against the
``home-assistant/brands`` repository required. This script produces the
two PNGs that folder needs from the *official MeteoSwiss app icon*:

- ``icon.png``    - 256x256
- ``icon@2x.png`` - 512x512

The generated files ARE committed, to
``custom_components/meteoswiss_radar/brand/``: that folder is the
delivery mechanism, so the icons have to be in the release artifact.
This script exists to reproduce them when the app icon changes, not as a
build step -- nothing calls it automatically.

The source is the App Store artwork for the official MeteoSwiss app
(``ch.admin.meteoswiss``, publisher "Federal Office of Meteorology and
Climatology MeteoSwiss"), looked up via the public iTunes Search API. The
artwork is a fully square, opaque icon with no rounded-corner alpha baked
in, which is exactly what is wanted here (the HA frontend applies its own
masking).

Usage::

    pip install Pillow
    python scripts/generate_brands_icon.py --overwrite

Writes into the shipped ``brand/`` folder by default; pass ``--out`` to
render somewhere else for inspection. Existing icons require explicit
``--overwrite``. Parent traversal and symlink outputs are rejected.
Requires network access and Pillow. Standard library otherwise.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import tempfile
import urllib.request
from pathlib import Path

# Official MeteoSwiss app on the App Store. The bundle id is the stable
# anchor; the display name and artwork URL can change over time.
APP_BUNDLE_ID = "ch.admin.meteoswiss"
SEARCH_URL = (
    "https://itunes.apple.com/search"
    "?term=meteoswiss&country=ch&entity=software&limit=25"
)
USER_AGENT = "hass-meteoswiss-radar brands-icon-generator (issue #84)"

# Required outputs: (filename, edge length in px).
OUTPUTS = (("icon.png", 256), ("icon@2x.png", 512))

# The shipped brand folder, served by the HA brands proxy API (HA 2026.3+).
BRAND_DIR = (
    Path(__file__).resolve().parent.parent
    / "custom_components"
    / "meteoswiss_radar"
    / "brand"
)


def _get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def find_artwork_url(bundle_id: str) -> str:
    """Return the App Store artwork URL for the given bundle id."""
    data = json.loads(_get(SEARCH_URL))
    for result in data.get("results", []):
        if result.get("bundleId") == bundle_id:
            url = result.get("artworkUrl512") or result.get("artworkUrl100")
            if not url:
                raise SystemExit(f"No artwork URL in result for {bundle_id}")
            return url
    raise SystemExit(
        f"App {bundle_id!r} not found in iTunes search results. "
        "Check the bundle id or pass --source-url explicitly."
    )


def upscale_request(url: str, size: int) -> str:
    """Ask Apple for a larger master so the downscale stays crisp.

    Artwork URLs end in ``/<w>x<h>bb.jpg``; swapping the dimensions asks
    the CDN to render at that size. We request the master at 2x the
    largest output so the LANCZOS downscale has headroom.
    """
    return re.sub(r"/\d+x\d+bb\.(jpg|png)$", f"/{size}x{size}bb.\\1", url)


def prepare_output_dir(value: str, *, overwrite: bool = False) -> Path:
    """Validate the operator's output choice before fetching any artwork."""
    path = Path(value).expanduser()
    if ".." in path.parts:
        raise ValueError("--out must not contain '..'; use an explicit directory")
    if path.is_symlink():
        raise ValueError("--out must not be a symbolic link")
    out_dir = path.resolve()
    if out_dir.exists() and not out_dir.is_dir():
        raise ValueError("--out must be a directory")
    for filename, _ in OUTPUTS:
        target = out_dir / filename
        if target.is_symlink():
            raise ValueError(f"Refusing symbolic-link output: {target}")
        if target.exists() and (not overwrite or not target.is_file()):
            raise ValueError(
                f"Refusing existing output: {target}; "
                "use --overwrite only for regular icon files"
            )
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir


def write_icons(master, out_dir: Path, *, resample, overwrite: bool = False) -> None:
    """Publish complete PNGs without following or truncating existing targets."""
    # Recheck all targets before writing either image. Exclusive publication
    # also protects a target created after this check, including a symlink.
    out_dir = prepare_output_dir(str(out_dir), overwrite=overwrite)
    for filename, edge in OUTPUTS:
        target = out_dir / filename
        image = master.resize((edge, edge), resample)
        temporary = tempfile.NamedTemporaryFile(
            dir=out_dir, prefix=".radar-icon-", suffix=".png", delete=False
        )
        temporary_path = Path(temporary.name)
        try:
            with temporary:
                image.save(temporary, "PNG", optimize=True)
            if overwrite:
                # Replace the directory entry, not its inode: a hard-linked
                # destination must not modify the other link's contents.
                os.replace(temporary_path, target)
            else:
                os.link(temporary_path, target)
        finally:
            temporary_path.unlink(missing_ok=True)
        print(f"Wrote {target} ({edge}x{edge})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=str(BRAND_DIR),
        help=f"Output directory (default: {BRAND_DIR})",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Explicitly replace existing regular icon files (never symlinks)",
    )
    parser.add_argument(
        "--source-url",
        default=None,
        help="Override the App Store artwork URL (skips the iTunes lookup)",
    )
    args = parser.parse_args()

    try:
        out_dir = prepare_output_dir(args.out, overwrite=args.overwrite)
    except (OSError, ValueError) as error:
        parser.error(str(error))

    try:
        from PIL import Image
    except ImportError:
        raise SystemExit("Pillow is required: pip install Pillow") from None

    source_url = args.source_url or find_artwork_url(APP_BUNDLE_ID)
    master_size = max(edge for _, edge in OUTPUTS) * 2
    master_url = upscale_request(source_url, master_size)
    print(f"Fetching master artwork: {master_url}")

    master = Image.open(io.BytesIO(_get(master_url))).convert("RGB")
    if master.width != master.height:
        raise SystemExit(
            f"Source artwork is not square ({master.size}); refusing to "
            "distort a logo. Inspect the source manually."
        )

    try:
        write_icons(
            master, out_dir, resample=Image.LANCZOS, overwrite=args.overwrite
        )
    except (OSError, ValueError) as error:
        raise SystemExit(f"Cannot write brand icons: {error}") from None

    print(
        "\nDone. Commit the result if you rendered into the shipped brand "
        "folder; Home Assistant picks it up on the next restart. "
        "See docs/brands-icon.md."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
