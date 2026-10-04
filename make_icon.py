# 앱 아이콘(1024x1024 PNG)을 만들어요. 빌드할 때 GitHub에서 자동으로 실행돼요.
import os, struct, zlib

N = 1024
TOP, BOT = (72, 84, 214), (38, 34, 120)
BARS = [180, 320, 480, 620, 480, 320, 180]
BW, GAP = 70, 38
X0 = (N - (len(BARS) * BW + (len(BARS) - 1) * GAP)) // 2
DOT = (N - 215, 215, 45)  # 노란 점: 중심 x, y, 반지름


def inside_bar(x, y):
    for i, h in enumerate(BARS):
        left = X0 + i * (BW + GAP)
        if left <= x < left + BW:
            r = BW / 2
            top, bottom = (N - h) / 2, (N + h) / 2
            cx = left + r
            if top + r <= y <= bottom - r:
                return True
            cy = top + r if y < top + r else bottom - r
            return (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r
    return False


rows = []
for y in range(N):
    t = y / (N - 1)
    bg = bytes(int(TOP[k] * (1 - t) + BOT[k] * t) for k in range(3))
    row = bytearray(b"\x00")
    for x in range(N):
        if inside_bar(x, y):
            row += b"\xff\xff\xff"
        elif (x - DOT[0]) ** 2 + (y - DOT[1]) ** 2 <= DOT[2] ** 2:
            row += bytes((255, 196, 87))
        else:
            row += bg
    rows.append(bytes(row))


def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")

out = "Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "wb") as f:
    f.write(png)
print("아이콘 만들기 완료:", out)
