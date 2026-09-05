#!/usr/bin/env python3
"""Measure a screenshot instead of guessing at it.

Written in an adopter project because of a specific, recorded mistake, and
promoted here once it had earned it. A feed title was set to 22pt by
reasoning from the surrounding layout; the reference app's is ~17pt. The
promotion was backwards, and it only read wrong when the two screens sat
side by side — it cost two correction rounds in one day. The lesson it was
written under:

    A promoted size is a guess until it sits beside the reference.

This answers the measurable third of that problem exactly, and refuses the
rest. It reports pixels and colours, converts to points when told the
device's logical width, and never guesses a font family, an easing curve or
a pressed state — none of which are in a still frame at all. A tool that
reports a guess in the same shape as a measurement is worse than no tool,
because the guess gets acted on.

Deliberately dependency-light and path-agnostic: Pillow, argparse, and no
knowledge of any particular project.

Delivered by `pe install` to docs/templates/tools/ — copy-once, so edits
made in an adopter survive an engine upgrade. `design-critic` shells out to
it (Step 4) rather than estimating drift it could measure.

    ./measure_screenshot.py colour  shot.png 120 340
    ./measure_screenshot.py rules   shot.png --x0 40 --x1 1160
    ./measure_screenshot.py ink     shot.png 40 300 380 340 --device-width 402
    ./measure_screenshot.py gap     shot.png 40 300 380 340 --device-width 402
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple

try:
    from PIL import Image
except ImportError:  # pragma: no cover - install guidance, not logic
    sys.exit("measure_screenshot: Pillow is required (pip install Pillow)")

RGB = Tuple[int, int, int]


def _hex(rgb: Sequence[int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb[:3])


def _load(path: str) -> Image.Image:
    return Image.open(path).convert("RGB")


def _scale(image: Image.Image, device_width: Optional[float]) -> Optional[float]:
    """Pixels per point, or None when the caller did not say.

    A screenshot has no idea what a point is. iPhone 17 Pro is 402pt wide and
    its screenshots are 1206px, so the factor is 3 — but a downscaled copy of
    the same screenshot is a different factor for the same device, which is
    why this is derived from the actual image and not from a device table.
    Without it every measurement stays in pixels and says so, rather than
    quietly reporting a point value that is wrong by a factor of two or three.
    """
    if not device_width:
        return None
    return image.width / device_width


def _pt(px: float, scale: Optional[float]) -> Optional[float]:
    return round(px / scale, 2) if scale else None


# ── colour ──────────────────────────────────────────────────────────


def cmd_colour(args: argparse.Namespace) -> Dict[str, Any]:
    """The colour at one point.

    One pixel, not a cluster average. Palette extractors average across
    anti-aliased edges, which is right for "what is the mood of this image"
    and wrong for "is this fill exactly #0c0c0e" — the question a design
    token actually asks.
    """
    image = _load(args.image)
    rgb = image.getpixel((args.x, args.y))
    return {"x": args.x, "y": args.y, "hex": _hex(rgb), "rgb": list(rgb)}


# ── horizontal rules ────────────────────────────────────────────────


def _close(a: RGB, b: RGB, tolerance: int) -> bool:
    return max(abs(a[i] - b[i]) for i in range(3)) <= tolerance


def _row_is_flat(row: List[RGB], tolerance: int) -> bool:
    lo = [min(c[i] for c in row) for i in range(3)]
    hi = [max(c[i] for c in row) for i in range(3)]
    return all(hi[i] - lo[i] <= tolerance for i in range(3))


def _scan_rules(image: "Image.Image", x0: int, x1: int, scale: Optional[float],
                tolerance: int, contrast: int) -> List[Dict[str, Any]]:
    """Walk the rows once, opening and extending runs.

    Split out of cmd_rules to meet the engine's 50-line function budget when
    this was promoted; the loop is the whole algorithm and the caller is now
    just argument plumbing.
    """
    pixels = image.load()
    found: List[Dict[str, Any]] = []
    previous: Optional[List[RGB]] = None
    run: Optional[Dict[str, Any]] = None

    for y in range(image.height):
        row = [pixels[x, y] for x in range(x0, x1)]
        if not _row_is_flat(row, tolerance):
            run, previous = None, row
            continue

        # A thick rule is ONE rule. Its second and third rows contrast with
        # nothing — the row above them is the rule itself — so they can only
        # be found by extending the run that is already open. An earlier
        # version merged adjacent hits afterwards instead, which could never
        # fire for exactly this reason and reported a 3px rule as 1px.
        if run is not None and _close(row[0], run["_rgb"], tolerance):
            run["y_end"] = y
            run["thickness_px"] = run["y_end"] - run["y"] + 1
            previous = row
            continue

        # A rule has to CONTRAST with what is above it. Without this every row
        # of a flat background qualifies and the answer is the whole image.
        if previous is not None and not _close(row[0], previous[0], contrast):
            run = {"y": y, "hex": _hex(row[0]), "pt": _pt(y, scale),
                   "y_end": y, "thickness_px": 1, "_rgb": row[0]}
            found.append(run)
        else:
            run = None
        previous = row

    for rule in found:
        del rule["_rgb"]
    return found


def cmd_rules(args: argparse.Namespace) -> Dict[str, Any]:
    """Find the horizontal rules — the borders and dividers.

    "Does this card have a border" is a question we have got wrong by eye in
    both directions, and it is answerable exactly: a rule is a row that is
    flat across the scanned span AND differs from the row above it. Scanning
    a horizontal span rather than the full width lets the caller exclude a
    column of text or an icon that would otherwise break every row.

    Not Canny/Hough. Edge detectors find real edges and also every text
    baseline and icon boundary, and then the caller has to decide which are
    which — for this one question a flat-row scan is both simpler and more
    predictable about what it will report.
    """
    image = _load(args.image)
    x0 = args.x0 if args.x0 is not None else 0
    x1 = args.x1 if args.x1 is not None else image.width
    found = _scan_rules(image, x0, x1, _scale(image, args.device_width),
                        args.tolerance, args.contrast)
    return {"span": [x0, x1], "count": len(found), "rules": found}


# ── ink extent ──────────────────────────────────────────────────────


def cmd_ink(args: argparse.Namespace) -> Dict[str, Any]:
    """The bounding box of everything that is not the background, in a region.

    This is how a type size gets measured: box the text, and the height of the
    ink is its cap height (or its full ascender-to-descender span, depending
    what letters are in it — which is why the result is labelled `ink_height`
    and NOT `font_size`).

    The conversion from cap height to point size depends on the typeface's own
    metrics, and the typeface is one of the things a screenshot does not
    contain. So this reports what it measured and stops. Comparing the SAME
    measurement between two screenshots — ours and the reference — is the
    honest use, and is exactly the comparison the D3a mistake needed.
    """
    image = _load(args.image)
    region = image.crop((args.x0, args.y0, args.x1, args.y1))
    pixels = region.load()
    background = pixels[0, 0]
    scale = _scale(image, args.device_width)

    def ink(x: int, y: int) -> bool:
        px = pixels[x, y]
        return max(abs(px[i] - background[i]) for i in range(3)) > args.tolerance

    xs = [x for x in range(region.width)
          for y in range(region.height) if ink(x, y)]
    ys = [y for y in range(region.height)
          for x in range(region.width) if ink(x, y)]

    if not xs or not ys:
        return {"found": False, "background": _hex(background),
                "note": "nothing differed from the top-left pixel by more "
                        "than the tolerance — check the region or raise it"}

    height = max(ys) - min(ys) + 1
    width = max(xs) - min(xs) + 1
    return {
        "found": True,
        "background": _hex(background),
        "ink_height_px": height,
        "ink_height_pt": _pt(height, scale),
        "ink_width_px": width,
        "ink_width_pt": _pt(width, scale),
        "box": {"x0": args.x0 + min(xs), "y0": args.y0 + min(ys),
                "x1": args.x0 + max(xs), "y1": args.y0 + max(ys)},
    }


# ── gap ─────────────────────────────────────────────────────────────


def cmd_gap(args: argparse.Namespace) -> Dict[str, Any]:
    """Straight-line distance between two points, in px and pt.

    The dullest command here and the one that answers most questions: how far
    apart are these two cards, how wide is that margin, how tall is that row.
    """
    image = _load(args.image)
    scale = _scale(image, args.device_width)
    dx = abs(args.x1 - args.x0)
    dy = abs(args.y1 - args.y0)
    return {
        "dx_px": dx, "dy_px": dy,
        "dx_pt": _pt(dx, scale), "dy_pt": _pt(dy, scale),
        "scale_px_per_pt": round(scale, 4) if scale else None,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Measure a screenshot: colours, rules, ink extents, gaps.")
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("image")
        p.add_argument("--device-width", type=float, default=None,
                       help="the device's logical width in POINTS (e.g. 402 "
                            "for iPhone 17 Pro). Without it, results stay in "
                            "pixels rather than reporting a wrong point value.")

    p_colour = sub.add_parser("colour", aliases=["color"])
    common(p_colour)
    p_colour.add_argument("x", type=int)
    p_colour.add_argument("y", type=int)
    p_colour.set_defaults(func=cmd_colour)

    p_rules = sub.add_parser("rules")
    common(p_rules)
    p_rules.add_argument("--x0", type=int, default=None)
    p_rules.add_argument("--x1", type=int, default=None)
    p_rules.add_argument("--tolerance", type=int, default=6,
                         help="how much a row may vary and still count flat")
    p_rules.add_argument("--contrast", type=int, default=10,
                         help="how much a rule must differ from the row above")
    p_rules.set_defaults(func=cmd_rules)

    for name, func in (("ink", cmd_ink), ("gap", cmd_gap)):
        p = sub.add_parser(name)
        common(p)
        for coord in ("x0", "y0", "x1", "y1"):
            p.add_argument(coord, type=int)
        if name == "ink":
            p.add_argument("--tolerance", type=int, default=40,
                           help="how far a pixel must sit from the region's "
                                "top-left pixel to count as ink")
        p.set_defaults(func=func)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    print(json.dumps(args.func(args), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
