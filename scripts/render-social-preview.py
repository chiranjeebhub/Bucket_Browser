# Renders docs/social-preview.png, the 1280x640 banner used for the GitHub social preview and the README.
# Usage: python3 scripts/render-social-preview.py . docs/social-preview.png  (needs Pillow and the Inter font)
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
repo = sys.argv[1]; out = sys.argv[2]
W, H, S = 1280, 640, 2  # draw at 2x, downsample
w, h = W*S, H*S
F = "/usr/share/fonts/opentype/inter/"
def font(n, size): return ImageFont.truetype(F+n, size*S)

# background: vertical navy gradient with a soft blue glow
bg = Image.new("RGB", (w, h))
top, bot = (14, 27, 48), (8, 15, 28)
d = ImageDraw.Draw(bg)
for y in range(h):
    t = y/h
    d.line([(0,y),(w,y)], fill=tuple(int(top[i]+(bot[i]-top[i])*t) for i in range(3)))
glow = Image.new("L", (w, h), 0)
ImageDraw.Draw(glow).ellipse([w*0.45, -h*0.3, w*1.3, h*1.1], fill=110)
glow = glow.filter(ImageFilter.GaussianBlur(160*S))
bg = Image.composite(Image.new("RGB",(w,h),(47,134,214)), bg, glow)
glow2 = Image.new("L", (w, h), 0)
ImageDraw.Draw(glow2).ellipse([-w*0.2, h*0.55, w*0.35, h*1.4], fill=70)
glow2 = glow2.filter(ImageFilter.GaussianBlur(140*S))
bg = Image.composite(Image.new("RGB",(w,h),(243,128,32)), bg, glow2).convert("RGBA")

# screenshot on the right, bleeding off the edge
shot = Image.open(f"{repo}/docs/screenshots/list-view.png").convert("RGBA")
sw = 800*S
shot = shot.resize((sw, int(shot.height*sw/shot.width)), Image.LANCZOS)
x0, y0 = 590*S, 128*S
mask = Image.new("L", shot.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0,0,shot.width-1,shot.height-1], radius=22*S, fill=255)
shadow = Image.new("RGBA", (w, h), (0,0,0,0))
ImageDraw.Draw(shadow).rounded_rectangle([x0, y0+18*S, x0+shot.width, y0+shot.height+18*S], radius=22*S, fill=(0,0,0,170))
shadow = shadow.filter(ImageFilter.GaussianBlur(30*S))
bg = Image.alpha_composite(bg, shadow)
bg.paste(shot, (x0, y0), mask)


# left: icon, title, tagline, chips
d = ImageDraw.Draw(bg)
icon = Image.open(f"{repo}/Resources/AppIcon.png").convert("RGBA").resize((200*S, 200*S), Image.LANCZOS)
bg.alpha_composite(icon, (52*S, 92*S))
d.text((72*S, 306*S), "Bucket Browser", font=font("InterDisplay-Bold.otf", 60), fill="white")
tag = font("Inter-Regular.otf", 24)
for i, line in enumerate(["Browse Amazon S3, Cloudflare R2 and", "S3-compatible storage on your Mac."]):
    d.text((74*S, (392+i*34)*S), line, font=tag, fill=(196, 210, 228))
cx, cy = 74*S, 488*S
cf = font("Inter-SemiBold.otf", 18)
for label in ["Native macOS", "Private", "Open source"]:
    tw = d.textlength(label, font=cf)
    ov = Image.new("RGBA", (w, h), (0,0,0,0))
    ImageDraw.Draw(ov).rounded_rectangle([cx, cy, cx+tw+28*S, cy+38*S], radius=19*S, fill=(255,255,255,26), outline=(255,255,255,70), width=S)
    bg.alpha_composite(ov); d = ImageDraw.Draw(bg)
    d.text((cx+14*S, cy+8*S), label, font=cf, fill="white")
    cx += tw + 40*S
bg.convert("RGB").resize((W, H), Image.LANCZOS).save(out, optimize=True)
