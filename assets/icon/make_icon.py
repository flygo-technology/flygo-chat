from PIL import Image, ImageDraw, ImageFont, ImageFilter
S = 1024
def gradient(size, c1, c2):
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size - 2)
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return g

def glyph(size, scale=1.0, shadow=True):
    """Bong bóng chat trắng + chữ F có vệt bay, trên nền trong suốt."""
    L = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(L)
    k = size / 1024 * scale
    cx = size / 2
    w, h = 640 * k, 540 * k
    x0, y0 = cx - w / 2, size / 2 - h / 2 - 30 * k
    bubble = [x0, y0, x0 + w, y0 + h]
    if shadow:
        sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        sd = ImageDraw.Draw(sh)
        sd.rounded_rectangle([bubble[0], bubble[1] + 18 * k, bubble[2], bubble[3] + 18 * k], radius=190 * k, fill=(0, 60, 40, 90))
        sh = sh.filter(ImageFilter.GaussianBlur(22 * k))
        L.alpha_composite(sh)
    d.rounded_rectangle(bubble, radius=190 * k, fill="white")
    # đuôi bong bóng (dưới trái)
    tx, ty = x0 + 120 * k, y0 + h - 10 * k
    d.polygon([(tx, ty - 60 * k), (tx - 70 * k, ty + 110 * k), (tx + 150 * k, ty - 20 * k)], fill="white")
    # chữ F
    font = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", int(380 * k), index=8)  # Heavy
    text = "F"
    bb = d.textbbox((0, 0), text, font=font)
    fw, fh = bb[2] - bb[0], bb[3] - bb[1]
    fx = cx - fw / 2 + 40 * k - bb[0]
    fy = y0 + h / 2 - fh / 2 - bb[1] - 6 * k
    green = (20, 104, 220)
    d.text((fx, fy), text, font=font, fill=green)
    # vệt bay bên trái chữ F
    lx = fx + bb[0] - 40 * k
    for i, (off, ln) in enumerate([(-80, 150), (0, 200), (80, 120)]):
        yy = y0 + h / 2 + off * k
        d.rounded_rectangle([lx - ln * k, yy - 15 * k, lx - 10 * k, yy + 15 * k], radius=15 * k, fill=green)
    return L

bg = gradient(S, (64, 160, 255), (12, 82, 200))
# icon đầy đủ (iOS/macOS/Windows/Linux, Android cũ)
full = bg.convert("RGBA")
full.alpha_composite(glyph(S, 1.0))
full.save("assets/icon/icon.png")
# Android adaptive: nền + tiền cảnh trong vùng an toàn (~66%)
bg.save("assets/icon/background.png")
glyph(S, 0.72, shadow=False).save("assets/icon/foreground.png")
# bản tròn bo góc để xem trước
prev = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mask = Image.new("L", (S, S), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, S, S], radius=230, fill=255)
prev.paste(full, (0, 0), mask); prev.resize((512, 512)).save("/private/tmp/claude-501/-Users-baduongvan-dev/26bcf400-4072-45c7-8bea-11b33813a935/scratchpad/icon_preview.png")
print("ok")
