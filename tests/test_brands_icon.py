"""Tests for the brand icon set and its generator (issue #84).

The generator tests are pure logic: no network, no Pillow. They guard the
two footguns in scripts/generate_brands_icon.py - the App Store
artwork-URL rewrite and picking the correct app out of the iTunes search
results by bundle id.

The shipped-asset tests guard the files themselves. Since HA 2026.3 the
brands proxy API serves custom_components/meteoswiss_radar/brand/ in
preference to the brands CDN, so those PNGs are a release artifact: if
they go missing or change shape, every user falls back to the
puzzle-piece icon and nothing else in the suite would notice.
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "generate_brands_icon.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("generate_brands_icon", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gbi = _load_module()


def test_upscale_request_rewrites_dimensions():
    url = (
        "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/57/47/da/"
        "abc/AppIcon-0-0-85-220.png/512x512bb.jpg"
    )
    assert gbi.upscale_request(url, 1024).endswith("/1024x1024bb.jpg")


def test_upscale_request_keeps_png_extension():
    url = "https://example.test/thumb/foo/100x100bb.png"
    assert gbi.upscale_request(url, 512) == "https://example.test/thumb/foo/512x512bb.png"


def test_upscale_request_leaves_unrecognised_url_untouched():
    url = "https://example.test/icon.png"
    assert gbi.upscale_request(url, 512) == url


def test_find_artwork_url_matches_bundle_id(monkeypatch):
    payload = {
        "results": [
            {"bundleId": "ch.srf.meteo", "artworkUrl512": "https://x/srf.jpg"},
            {
                "bundleId": gbi.APP_BUNDLE_ID,
                "artworkUrl512": "https://x/meteoswiss.jpg",
            },
        ]
    }
    monkeypatch.setattr(gbi, "_get", lambda url: json.dumps(payload).encode())
    assert gbi.find_artwork_url(gbi.APP_BUNDLE_ID) == "https://x/meteoswiss.jpg"


def test_find_artwork_url_raises_when_absent(monkeypatch):
    monkeypatch.setattr(gbi, "_get", lambda url: b'{"results": []}')
    with pytest.raises(SystemExit):
        gbi.find_artwork_url(gbi.APP_BUNDLE_ID)


# --- Shipped brand assets -------------------------------------------------
#
# Deliberately parsed by hand rather than with Pillow: the suite must run
# without Pillow installed, and a PNG header check is enough to catch the
# realistic failure modes (file missing, truncated, wrong dimensions, or a
# JPEG renamed to .png).

BRAND_DIR = ROOT / "custom_components" / "meteoswiss_radar" / "brand"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _png_size(path: Path) -> tuple[int, int]:
    """Return (width, height) from the IHDR chunk of a PNG."""
    header = path.read_bytes()[:24]
    assert header[:8] == PNG_MAGIC, f"{path.name} is not a PNG"
    assert header[12:16] == b"IHDR", f"{path.name} has no leading IHDR chunk"
    width = int.from_bytes(header[16:20], "big")
    height = int.from_bytes(header[20:24], "big")
    return width, height


@pytest.mark.parametrize(("filename", "edge"), gbi.OUTPUTS)
def test_shipped_brand_icon_has_expected_dimensions(filename, edge):
    path = BRAND_DIR / filename
    assert path.is_file(), (
        f"{filename} is missing from {BRAND_DIR.name}/ - HA falls back to the "
        "puzzle-piece icon. Regenerate with scripts/generate_brands_icon.py."
    )
    assert _png_size(path) == (edge, edge)


def test_shipped_brand_icons_match_generator_outputs():
    """The folder holds exactly what the generator produces - no strays."""
    expected = {filename for filename, _ in gbi.OUTPUTS}
    actual = {p.name for p in BRAND_DIR.iterdir() if p.is_file()}
    assert actual == expected


def test_generator_defaults_to_the_shipped_brand_folder():
    """Guards the default --out; a drifted path silently stops shipping."""
    assert gbi.BRAND_DIR == BRAND_DIR


class _RenderedIcon:
    """Exercise the writer's filesystem behavior without requiring Pillow."""

    def save(self, stream, image_format, *, optimize):
        assert image_format == "PNG"
        assert optimize is True
        stream.write(b"rendered icon")


class _MasterIcon:
    def resize(self, size, resample):
        assert size in ((256, 256), (512, 512))
        return _RenderedIcon()


def _write_icons(out_dir, *, overwrite=False, master=None):
    gbi.write_icons(
        master or _MasterIcon(), out_dir, resample=None, overwrite=overwrite
    )


def test_generator_allows_an_explicit_new_preview_directory(tmp_path):
    out_dir = tmp_path / "preview" / "icons"
    result = gbi.prepare_output_dir(str(out_dir))
    assert result == out_dir.resolve()
    _write_icons(result)
    assert {p.name for p in result.iterdir()} == {name for name, _ in gbi.OUTPUTS}
    assert all(p.read_bytes() == b"rendered icon" for p in result.iterdir())


def test_generator_rejects_parent_traversal_before_creating_directories(tmp_path):
    with pytest.raises(ValueError, match="must not contain"):
        gbi.prepare_output_dir(str(tmp_path / "preview" / ".." / "other"))
    assert list(tmp_path.iterdir()) == []


def test_generator_rejects_an_output_file(tmp_path):
    out_file = tmp_path / "not-a-directory"
    out_file.write_bytes(b"keep")
    with pytest.raises(ValueError, match="must be a directory"):
        gbi.prepare_output_dir(str(out_file))
    assert out_file.read_bytes() == b"keep"


@pytest.mark.parametrize("dangling", [False, True])
def test_generator_rejects_output_directory_symlinks(tmp_path, dangling):
    destination = tmp_path / "elsewhere"
    if not dangling:
        destination.mkdir()
    link = tmp_path / "output"
    link.symlink_to(destination, target_is_directory=True)
    with pytest.raises(ValueError, match="must not be a symbolic link"):
        gbi.prepare_output_dir(str(link), overwrite=True)
    assert link.is_symlink()


@pytest.mark.parametrize("overwrite", [False, True])
@pytest.mark.parametrize("dangling", [False, True])
def test_generator_never_follows_icon_symlinks(tmp_path, overwrite, dangling):
    destination = tmp_path / "other-file"
    if not dangling:
        destination.write_bytes(b"keep")
    link = tmp_path / "icon@2x.png"
    link.symlink_to(destination)
    with pytest.raises(ValueError, match="symbolic-link output"):
        _write_icons(tmp_path, overwrite=overwrite)
    assert link.is_symlink()
    assert not (tmp_path / "icon.png").exists()
    assert destination.exists() is not dangling
    if not dangling:
        assert destination.read_bytes() == b"keep"


def test_generator_checks_both_icons_before_replacing_either(tmp_path):
    existing = tmp_path / "icon@2x.png"
    existing.write_bytes(b"keep")
    with pytest.raises(ValueError, match="Refusing existing output"):
        _write_icons(tmp_path)
    assert existing.read_bytes() == b"keep"
    assert not (tmp_path / "icon.png").exists()
    assert {p.name for p in tmp_path.iterdir()} == {"icon@2x.png"}


def test_generator_requires_explicit_overwrite(tmp_path):
    _write_icons(tmp_path)
    with pytest.raises(ValueError, match="use --overwrite"):
        _write_icons(tmp_path)
    _write_icons(tmp_path, overwrite=True)
    assert {p.name for p in tmp_path.iterdir()} == {name for name, _ in gbi.OUTPUTS}


def test_generator_replaces_a_hard_link_without_modifying_its_source(tmp_path):
    original = tmp_path / "original"
    original.write_bytes(b"keep")
    target = tmp_path / "icon.png"
    os.link(original, target)
    _write_icons(tmp_path, overwrite=True)
    assert original.read_bytes() == b"keep"
    assert target.read_bytes() == b"rendered icon"
    assert not original.samefile(target)


def test_generator_does_not_clobber_a_target_created_during_render(tmp_path):
    class RacingIcon(_RenderedIcon):
        def save(self, stream, image_format, *, optimize):
            super().save(stream, image_format, optimize=optimize)
            (tmp_path / "icon.png").write_bytes(b"created by another process")

    class RacingMaster:
        def resize(self, size, resample):
            return RacingIcon()

    with pytest.raises(FileExistsError):
        _write_icons(tmp_path, master=RacingMaster())
    assert (tmp_path / "icon.png").read_bytes() == b"created by another process"
    assert {p.name for p in tmp_path.iterdir()} == {"icon.png"}


def test_generator_cleans_up_when_rendering_fails(tmp_path):
    class BrokenIcon:
        def save(self, stream, image_format, *, optimize):
            stream.write(b"partial render")
            raise OSError("render failed")

    class BrokenMaster:
        def resize(self, size, resample):
            return BrokenIcon()

    with pytest.raises(OSError, match="render failed"):
        _write_icons(tmp_path, master=BrokenMaster())
    assert list(tmp_path.iterdir()) == []


def test_generator_rejects_bad_cli_paths_before_any_download(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.argv", [str(SCRIPT), "--out", str(tmp_path / "..")])
    downloads = []
    monkeypatch.setattr(gbi, "_get", lambda url: downloads.append(url))
    with pytest.raises(SystemExit) as result:
        gbi.main()
    assert result.value.code == 2
    assert downloads == []
