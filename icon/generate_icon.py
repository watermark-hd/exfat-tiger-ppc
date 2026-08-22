from PIL import Image, ImageDraw, ImageFilter
import math

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

def rounded_rect_mask(size, radius):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size[0]-1, size[1]-1], radius=radius, fill=255)
    return m

pad = 90

# --- drop shadow for background square ---
shadow = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle([pad, pad+28, SIZE-pad, SIZE-pad+28], radius=180, fill=(0,0,0,110))
shadow = shadow.filter(ImageFilter.GaussianBlur(24))
img = Image.alpha_composite(img, shadow)

# --- main body: rounded square, aqua gradient (Tiger-era blue) ---
body_size = (SIZE - 2*pad, SIZE - 2*pad)
grad = Image.new("RGBA", body_size, (0,0,0,0))
top = (150, 205, 245)
bottom = (20, 90, 175)
for y in range(body_size[1]):
    t = y / body_size[1]
    r = int(top[0] + (bottom[0]-top[0])*t)
    g = int(top[1] + (bottom[1]-top[1])*t)
    b = int(top[2] + (bottom[2]-top[2])*t)
    ImageDraw.Draw(grad).line([(0,y),(body_size[0],y)], fill=(r,g,b,255))
mask = rounded_rect_mask(body_size, 170)
body = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))
body.paste(grad, (pad, pad), mask)
img = Image.alpha_composite(img, body)

border = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))
bd = ImageDraw.Draw(border)
bd.rounded_rectangle([pad, pad, SIZE-pad, SIZE-pad], radius=170, outline=(255,255,255,90), width=6)
img = Image.alpha_composite(img, border)

sheen_mask = Image.new("L", (SIZE, SIZE), 0)
smd = ImageDraw.Draw(sheen_mask)
smd.rounded_rectangle([pad+16, pad+16, SIZE-pad-16, pad+ (body_size[1]//2)], radius=140, fill=255)
sheen_layer = Image.new("RGBA", (SIZE, SIZE), (255,255,255,70))
sheen = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))
sheen = Image.composite(sheen_layer, sheen, sheen_mask)
img = Image.alpha_composite(img, sheen)

# =========================================================
# USB flash drive pictogram -- bigger, no badge
# =========================================================
drive_layer = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))

conn_w, conn_h = 170, 195
cap_w, cap_h = 430, 300
total_w = conn_w + cap_w - 20
total_h = max(conn_h, cap_h)

piece = Image.new("RGBA", (total_w + 40, total_h + 40), (0,0,0,0))
pd = ImageDraw.Draw(piece)
oy = (piece.height - total_h)//2

conn_rect = [20, oy + (total_h-conn_h)//2, 20+conn_w, oy + (total_h-conn_h)//2 + conn_h]
metal_grad = Image.new("RGBA", (conn_w, conn_h), (0,0,0,0))
for x in range(conn_w):
    t = x / conn_w
    shade = 210 - int(60*math.sin(t*math.pi))
    ImageDraw.Draw(metal_grad).line([(x,0),(x,conn_h)], fill=(shade, shade, shade+8, 255))
metal_mask = Image.new("L", (conn_w, conn_h), 0)
ImageDraw.Draw(metal_mask).rounded_rectangle([0,0,conn_w-1,conn_h-1], radius=22, fill=255)
piece.paste(metal_grad, (conn_rect[0], conn_rect[1]), metal_mask)
for i in range(5):
    lx = conn_rect[0] + 38 + i*62
    pd.line([(lx, conn_rect[1]+28),(lx, conn_rect[3]-28)], fill=(120,120,130,255), width=7)
pd.rounded_rectangle(conn_rect, radius=22, outline=(90,90,100,255), width=7)

cap_x0 = 20 + conn_w - 35
cap_rect = [cap_x0, oy + (total_h-cap_h)//2, cap_x0+cap_w, oy + (total_h-cap_h)//2 + cap_h]
cap_grad = Image.new("RGBA", (cap_w, cap_h), (0,0,0,0))
cap_top = (235, 245, 255)
cap_bottom = (255, 255, 255)
for y in range(cap_h):
    t = y / cap_h
    r = int(cap_top[0] + (cap_bottom[0]-cap_top[0])*t)
    g = int(cap_top[1] + (cap_bottom[1]-cap_top[1])*t)
    b = int(cap_top[2] + (cap_bottom[2]-cap_top[2])*t)
    ImageDraw.Draw(cap_grad).line([(0,y),(cap_w,y)], fill=(r,g,b,255))
cap_mask = Image.new("L", (cap_w, cap_h), 0)
ImageDraw.Draw(cap_mask).rounded_rectangle([0,0,cap_w-1,cap_h-1], radius=78, fill=255)
piece.paste(cap_grad, (cap_rect[0], cap_rect[1]), cap_mask)
pd.rounded_rectangle(cap_rect, radius=78, outline=(190,200,215,255), width=6)

stripe_margin = 44
stripe_rect = [cap_rect[0]+stripe_margin, cap_rect[1]+cap_h//2-48, cap_rect[2]-stripe_margin, cap_rect[1]+cap_h//2+48]
pd.rounded_rectangle(stripe_rect, radius=20, fill=(20,90,175,255))

hl_mask = Image.new("L", (cap_w, cap_h), 0)
ImageDraw.Draw(hl_mask).rounded_rectangle([16,12,cap_w-16,cap_h//2-12], radius=52, fill=255)
hl_layer = Image.new("RGBA", (cap_w, cap_h), (255,255,255,120))
hl = Image.new("RGBA", (cap_w, cap_h), (0,0,0,0))
hl = Image.composite(hl_layer, hl, hl_mask)
piece.paste(hl, (cap_rect[0], cap_rect[1]), hl_mask)

piece = piece.rotate(-18, expand=True, resample=Image.BICUBIC)

drive_shadow = Image.new("RGBA", piece.size, (0,0,0,0))
alpha = piece.split()[3]
shadow_layer = Image.new("RGBA", piece.size, (0,0,0,140))
drive_shadow = Image.composite(shadow_layer, drive_shadow, alpha)
drive_shadow = drive_shadow.filter(ImageFilter.GaussianBlur(16))

px = (SIZE - piece.width)//2
py = (SIZE - piece.height)//2 - 10
drive_layer.alpha_composite(drive_shadow, (px+12, py+18))
drive_layer.alpha_composite(piece, (px, py))

img = Image.alpha_composite(img, drive_layer)

img.save("/private/tmp/claude-501/-Users-watermark-developer-exFAT/ac7e11ee-f47c-4f8c-9ffc-77427b25d496/scratchpad/icon/icon_1024_v3.png")
print("saved")
