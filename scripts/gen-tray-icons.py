#!/usr/bin/env python3
"""Generate 22px tray silhouettes from the source artwork.

Reads icon/microphone with a document.png (NEVER writes it) and writes:
  src/assets/zhisper-tray-idle.png      gray  #999999 silhouette
  src/assets/zhisper-tray-recording.png red   #E03B30 silhouette
  src/assets/zhisper-tray-working.png   amber #E0A020 silhouette
Shape = badge alpha (non-background pixels), tinted per overlay stateTint.
PIL only, no numpy.
"""

from PIL import Image, ImageChops

SRC = "icon/microphone with a document.png"
SIZE = 22
TINTS = {
    "idle": (0x99, 0x99, 0x99),
    "recording": (0xE0, 0x3B, 0x30),
    "working": (0xE0, 0xA0, 0x20),
}
BG_TOLERANCE = 24
PAD_OUT = 2  # transparent margin in output px so points don't touch the slot edge


def load_cropped(src_path):
    im = Image.open(src_path).convert("RGB")
    w, h = im.size
    corners = [im.getpixel((0, 0)), im.getpixel((w - 1, 0)),
               im.getpixel((0, h - 1)), im.getpixel((w - 1, h - 1))]
    bg = corners[0]
    assert all(c == bg for c in corners), f"corners differ: {corners}"
    solid = Image.new("RGB", im.size, bg)
    mask = ImageChops.difference(im, solid).convert("L").point(
        lambda v: 255 if v > BG_TOLERANCE else 0)
    bbox = mask.getbbox()
    assert bbox, "no foreground found"
    bw, bh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    scale = (SIZE - 2 * PAD_OUT) / max(bw, bh)
    crop = mask.crop(bbox).resize((round(bw * scale), round(bh * scale)), Image.LANCZOS)
    square = Image.new("L", (SIZE, SIZE), 0)
    square.paste(crop, ((SIZE - crop.width) // 2, (SIZE - crop.height) // 2))
    return square


def main():
    alpha = load_cropped(SRC)
    for name, (r, g, b) in TINTS.items():
        out = Image.new("RGBA", (SIZE, SIZE), (r, g, b, 255))
        out.putalpha(alpha)
        path = f"src/assets/zhisper-tray-{name}.png"
        out.save(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
