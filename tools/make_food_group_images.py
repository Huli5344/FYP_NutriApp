"""Draw the food-group pictures as SVG, render them, and write WebP.

    python tools/make_food_group_images.py nutriapp/assets/food_groups

Then check them against the dataset:

    python tools/check_food_images.py nutriapp/assets/foods.db \\
        nutriapp/assets/food_groups

Run this when the dataset gains a food group, or to change a drawing. Add an
entry to MOTIFS keyed by the slug check_food_images.py asks for, and nothing
else needs touching -- foodGroupImage() derives the filename from the group
name, so a matching file is the whole integration.

Rendering needs Playwright with Chromium, and Pillow for the WebP:

    pip install playwright pillow && playwright install chromium

Constraints come from FoodImage in ui.dart, not from taste:

  * 1200x675. The same file is a 56pt square thumbnail in a list and a
    full-width header on a detail screen.
  * The square thumbnail takes the CENTRE. So the motif sits inside the
    central 675x675, and the sides carry only background -- anything placed
    out there is invisible in every list in the app.
  * Flat shapes, no gradients, no text. They are drawn in the app's own
    palette so a list of them reads as one surface rather than as a row of
    stickers, and no lettering means nothing to translate or re-render.

These are original drawings, not photographs: nothing to license, and a
group picture should not look like a specific dish anyway -- it stands for
581 beverages, not for one.
"""

import pathlib
import subprocess
import sys

W, H = 1200, 675
CX, CY = W // 2, H // 2

# The app's tokens (ui.dart). Backgrounds are tints of the same family so the
# set holds together; the motif is always the darkest value on the card.
INK = "#10232B"
ACCENT = "#13505B"
MID = "#4C7F88"
MUTE = "#5B6E75"
WARN = "#A75B12"
PAPER = "#F2F5F6"
TINT = "#EDF2F3"

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
OUT.mkdir(parents=True, exist_ok=True)


def card(bg, body, band=None):
    """A background, a faint band for depth, and the centred motif."""
    band = band or TINT
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}"
     viewBox="0 0 {W} {H}">
  <rect width="{W}" height="{H}" fill="{bg}"/>
  <circle cx="{CX}" cy="{CY}" r="210" fill="{band}"/>
  <g transform="translate({CX},{CY})" fill="none"
     stroke="{ACCENT}" stroke-width="14"
     stroke-linecap="round" stroke-linejoin="round">
{body}
  </g>
</svg>"""


# Every motif is drawn around (0,0) and stays inside roughly +/-150, so the
# square crop never clips it.
MOTIFS = {
    # A tumbler with a straw.
    "beverages": ("#E9F0F1", f"""
    <path d="M -70 -90 L 70 -90 L 56 96 A 18 18 0 0 1 38 112 L -38 112
             A 18 18 0 0 1 -56 96 Z"/>
    <path d="M -62 -28 L 62 -28" stroke="{MID}"/>
    <path d="M 24 -140 L 4 -90" stroke="{WARN}"/>"""),

    # A bowl of rice with a raised grain above it.
    "grains-and-staples": ("#EEF1EC", f"""
    <path d="M -118 10 L 118 10 A 118 118 0 0 1 -118 10 Z"/>
    <path d="M -142 10 L 142 10"/>
    <path d="M 0 -26 L 0 -142" stroke="{MID}"/>
    <path d="M 0 -132 q -34 -4 -40 -32 q 34 -2 40 32" stroke="{MID}"/>
    <path d="M 0 -132 q 34 -4 40 -32 q -34 -2 -40 32" stroke="{MID}"/>
    <path d="M 0 -94 q -34 -4 -40 -32 q 34 -2 40 32" stroke="{MID}"/>
    <path d="M 0 -94 q 34 -4 40 -32 q -34 -2 -40 32" stroke="{MID}"/>
    <path d="M 0 -56 q -34 -4 -40 -32 q 34 -2 40 32" stroke="{MID}"/>
    <path d="M 0 -56 q 34 -4 40 -32 q -34 -2 -40 32" stroke="{MID}"/>"""),

    # A cut of meat with a bone end.
    "meat-and-alternatives": ("#F2EDEA", f"""
    <path d="M -46 -116 q 108 -16 150 56 q 38 68 -38 110 q -82 44 -144 -8
             q -58 -48 -22 -108 q 20 -34 54 -50 Z"/>
    <circle cx="74" cy="40" r="34" stroke="{MID}"/>
    <path d="M -50 -40 q 34 30 8 74" stroke="{MID}"/>
    <path d="M -2 -74 q 36 32 8 80" stroke="{MID}"/>"""),

    # A snack packet, pinched at the top.
    "snacks": ("#F1EFE9", f"""
    <path d="M -86 -104 L 86 -104 L 100 112 L -100 112 Z"/>
    <path d="M -86 -104 q 86 34 172 0" stroke="{MID}"/>
    <path d="M -46 20 L 46 20" stroke="{MID}"/>"""),

    # Two leaves on a stem.
    "vegetables": ("#EAF0EA", f"""
    <path d="M 0 124 L 0 -16"/>
    <path d="M 0 -16 q -112 -18 -104 -112 q 96 -14 104 112 Z"/>
    <path d="M 0 34 q 100 -16 94 -100 q -86 -12 -94 100 Z" stroke="{MID}"/>"""),

    # A fish.
    "fish-and-seafood": ("#E8EFF2", f"""
    <path d="M -46 0 q 70 -90 148 0 q -78 90 -148 0 Z"/>
    <path d="M -46 0 L -118 -54 L -118 54 Z"/>
    <circle cx="66" cy="-14" r="9" fill="{ACCENT}" stroke="none"/>
    <path d="M 10 -44 q 18 44 0 88" stroke="{MID}"/>"""),

    # A drumstick.
    "poultry": ("#F2EFE8", f"""
    <ellipse cx="46" cy="-46" rx="94" ry="74"
             transform="rotate(-35 46 -46)"/>
    <path d="M -16 24 L -78 86" stroke-width="30"/>
    <circle cx="-102" cy="72" r="27"/>
    <circle cx="-70" cy="104" r="27"/>"""),

    # A bottle beside an egg.
    "dairy-and-eggs": ("#EDF1F3", f"""
    <path d="M -116 -96 L -42 -96 L -42 -46 q 22 20 22 52 L -20 108
             A 14 14 0 0 1 -34 122 L -124 122 A 14 14 0 0 1 -138 108
             L -138 6 q 0 -32 22 -52 Z"/>
    <path d="M -138 24 L -20 24" stroke="{MID}"/>
    <path d="M 86 -58 q 58 56 24 118 q -28 50 -78 22 q -44 -26 -24 -90
             q 16 -50 78 -50 Z" stroke="{MID}"/>"""),

    # A split pod with three seeds.
    "nuts-and-legumes": ("#EFEFE8", f"""
    <path d="M -130 44 q 36 -118 150 -116 q 110 2 102 70 q -8 62 -118 62
             q -102 0 -134 -16 Z"/>
    <circle cx="-56" cy="6" r="26" stroke="{MID}"/>
    <circle cx="14" cy="-8" r="26" stroke="{MID}"/>
    <circle cx="84" cy="4" r="26" stroke="{MID}"/>"""),

    # An apple with a leaf.
    "fruit": ("#F1ECEC", f"""
    <path d="M 0 -62 q -62 -46 -104 10 q -40 54 8 124 q 40 58 96 20
             q 56 38 96 -20 q 48 -70 8 -124 q -42 -56 -104 -10 Z"/>
    <path d="M 0 -62 L 0 -112"/>
    <path d="M 0 -104 q 52 -34 76 6 q -44 30 -76 -6 Z" stroke="{MID}"/>"""),

    # A cruet and a shaker.
    "oils-seasonings-and-condiments": ("#F2EFE7", f"""
    <path d="M -118 -74 L -56 -74 L -56 -34 q 26 22 26 58 L -30 108
             A 14 14 0 0 1 -44 122 L -130 122 A 14 14 0 0 1 -144 108
             L -144 24 q 0 -36 26 -58 Z"/>
    <path d="M -144 42 L -30 42" stroke="{MID}"/>
    <path d="M 58 -42 q 54 0 54 54 L 112 108 A 14 14 0 0 1 98 122
             L 18 122 A 14 14 0 0 1 4 108 L 4 12 q 0 -54 54 -54 Z"
          stroke="{MID}"/>
    <path d="M 40 -64 L 40 -42 M 58 -72 L 58 -42 M 76 -64 L 76 -42"
          stroke="{MID}"/>"""),

    # A slice of cake.
    "desserts": ("#F1ECEF", f"""
    <path d="M -110 108 L -110 -18 L 110 -18 L 110 108 Z"/>
    <path d="M -110 -18 q 56 -46 110 -46 q 54 0 110 46" stroke="{MID}"/>
    <path d="M -110 36 L 110 36" stroke="{MID}"/>
    <path d="M 0 -64 L 0 -112" stroke="{WARN}"/>"""),

    # A plate divided into portions.
    "mixed": ("#EDF1F0", f"""
    <circle cx="0" cy="0" r="130"/>
    <path d="M 0 -130 L 0 130" stroke="{MID}"/>
    <path d="M 0 0 L 130 0" stroke="{MID}"/>
    <circle cx="-64" cy="0" r="34" stroke="{MID}"/>"""),

    # A covered dish.
    "miscellaneous": ("#EFF1F2", f"""
    <path d="M -132 56 q 0 -132 132 -132 q 132 0 132 132 Z"/>
    <path d="M -150 56 L 150 56"/>
    <path d="M 0 -76 L 0 -116" stroke="{MID}"/>
    <circle cx="0" cy="-126" r="16" stroke="{MID}"/>"""),

    # A wrapped sweet.
    "sugar-and-confectionery": ("#F2EEEA", f"""
    <circle cx="0" cy="0" r="74"/>
    <path d="M -74 0 L -140 -56 L -140 56 Z" stroke="{MID}"/>
    <path d="M 74 0 L 140 -56 L 140 56 Z" stroke="{MID}"/>"""),

    # A plain bowl: whatever the dataset adds next.
    "fallback": (PAPER, f"""
    <path d="M -118 -10 L 118 -10 A 118 118 0 0 1 -118 -10 Z"/>
    <path d="M -142 -10 L 142 -10"/>
    <path d="M 0 -58 L 0 -96" stroke="{MUTE}"/>"""),
}

svg_dir = OUT / "_svg"
svg_dir.mkdir(exist_ok=True)
for name, (bg, body) in MOTIFS.items():
    (svg_dir / f"{name}.svg").write_text(card(bg, body), encoding="utf-8")
print(f"wrote {len(MOTIFS)} svg")

# --- render ---------------------------------------------------------------
#
# Chromium rather than an SVG library, because it is the renderer the output
# is judged against anyway and it needs no extra system packages.
try:
    from playwright.sync_api import sync_playwright
    from PIL import Image
except ImportError:
    print("\nSVG written. Install playwright and pillow to render WebP:")
    print("  pip install playwright pillow && playwright install chromium")
    raise SystemExit(0)

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": W, "height": H},
                            device_scale_factor=1)
    for svg in sorted(svg_dir.glob("*.svg")):
        page.goto(svg.resolve().as_uri())
        page.wait_for_timeout(60)
        page.screenshot(path=str(OUT / f"{svg.stem}.png"))
    browser.close()

total = 0
for png in sorted(OUT.glob("*.png")):
    image = Image.open(png).convert("RGB")
    assert image.size == (W, H), f"{png.name} rendered at {image.size}"
    # quality 88 is where these stop getting visibly better; the whole set is
    # under 100 KB, which matters because it ships inside the APK.
    image.save(OUT / f"{png.stem}.webp", "WEBP", quality=88, method=6)
    total += (OUT / f"{png.stem}.webp").stat().st_size
    png.unlink()

print(f"{len(list(OUT.glob('*.webp')))} webp written, {total / 1024:.0f} KB total")
print("Check them:  python tools/check_food_images.py "
      "nutriapp/assets/foods.db " + str(OUT))
