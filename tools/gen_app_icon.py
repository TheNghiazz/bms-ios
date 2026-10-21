#!/usr/bin/env python3
"""Sinh icon app (1024x1024, RGB không alpha) cho BMS Monitor.

Chỉ dùng stdlib (zlib + struct) nên chạy được trên Windows/CI, không cần Pillow.

    python tools/gen_app_icon.py
    # -> App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

Icon: nền "Industrial Dark" + viên pin màu xanh (giống màu SOC trong app)
với tia sét (BMS = mạch quản lý pin) và cực pin màu xanh dương.
"""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"

# Bảng màu lấy từ App/Theme.swift ("Industrial Dark").
BG_TOP = (11, 17, 32)
BG_BOTTOM = (22, 35, 59)
GLOW = (16, 185, 129)
GLOW_BLUE = (29, 78, 216)
GREEN_TOP = (62, 224, 160)
GREEN_BOTTOM = (10, 158, 110)
BLUE_TOP = (125, 211, 252)
BLUE_BOTTOM = (14, 165, 233)
INK = (7, 16, 31)

# Hình học (toạ độ pixel trên canvas 1024).
BODY = (480.0, 520.0, 300.0, 212.0, 118.0)      # cx, cy, half-w, half-h, radius
TERMINAL = (812.0, 520.0, 32.0, 60.0, 18.0)
BOLT = [
    (516.0, 358.0),
    (366.0, 556.0),
    (458.0, 556.0),
    (424.0, 702.0),
    (598.0, 488.0),
    (504.0, 488.0),
    (550.0, 358.0),
]


def clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def mix(a, b, t: float):
    t = clamp01(t)
    return (
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    )


def sd_round_rect(px, py, cx, cy, hw, hh, r):
    """Signed distance (px) từ điểm tới hình chữ nhật bo góc."""
    dx = abs(px - cx) - hw + r
    dy = abs(py - cy) - hh + r
    ox = dx if dx > 0.0 else 0.0
    oy = dy if dy > 0.0 else 0.0
    inside = dx if dx > dy else dy
    if inside > 0.0:
        inside = 0.0
    return math.hypot(ox, oy) + inside - r


def sd_polygon(px, py, pts):
    """Signed distance (px) tới đa giác; dương ở trong."""
    inside = False
    best = float("inf")
    n = len(pts)
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        if (y1 > py) != (y2 > py):
            if px < x1 + (py - y1) * (x2 - x1) / (y2 - y1):
                inside = not inside
        dx = x2 - x1
        dy = y2 - y1
        l2 = dx * dx + dy * dy
        t = ((px - x1) * dx + (py - y1) * dy) / l2 if l2 else 0.0
        t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
        ex = x1 + t * dx - px
        ey = y1 + t * dy - py
        d2 = ex * ex + ey * ey
        if d2 < best:
            best = d2
    d = math.sqrt(best)
    return d if inside else -d


def render() -> list[bytearray]:
    rows: list[bytearray] = []
    cx, cy, hw, hh, rad = BODY
    tcx, tcy, thw, thh, trad = TERMINAL

    bolt_x0 = min(p[0] for p in BOLT) - 3
    bolt_x1 = max(p[0] for p in BOLT) + 3
    bolt_y0 = min(p[1] for p in BOLT) - 3
    bolt_y1 = max(p[1] for p in BOLT) + 3
    bolt_shadow = [(x, y + 10.0) for x, y in BOLT]

    for y in range(SIZE):
        row = bytearray()
        v = y / (SIZE - 1)
        base = mix(BG_TOP, BG_BOTTOM, v ** 1.1)
        for x in range(SIZE):
            # Nền + 2 quầng sáng mờ.
            r, g, b = base
            dg = math.hypot(x - 470.0, y - 590.0) / 620.0
            if dg < 1.0:
                r, g, b = mix((r, g, b), GLOW, (1.0 - dg) ** 2 * 0.26)
            db2 = math.hypot(x - 300.0, y - 250.0) / 760.0
            if db2 < 1.0:
                r, g, b = mix((r, g, b), GLOW_BLUE, (1.0 - db2) ** 2 * 0.12)

            # Bóng đổ dưới viên pin.
            ds = sd_round_rect(x, y, cx, cy + 26.0, hw + 6.0, hh + 6.0, rad + 6.0)
            if ds < 1.5:
                r, g, b = mix((r, g, b), (2, 6, 16), clamp01(0.5 - ds) * 0.5)

            # Thân pin: gradient xanh + highlight phía trên.
            dbody = sd_round_rect(x, y, cx, cy, hw, hh, rad)
            if dbody < 1.5:
                cov = clamp01(0.5 - dbody)
                t = clamp01((y - (cy - hh)) / (2.0 * hh))
                col = mix(GREEN_TOP, GREEN_BOTTOM, t ** 0.85)
                col = mix(col, (255, 255, 255), (1.0 - t) ** 2 * 0.20)
                # Viền trong tối nhẹ cho khối pin sắc nét.
                ring = clamp01((dbody + 16.0) / 14.0)
                col = mix(col, (4, 72, 51), ring * 0.35)
                r = r + (col[0] - r) * cov
                g = g + (col[1] - g) * cov
                b = b + (col[2] - b) * cov

            if bolt_x0 <= x <= bolt_x1 and bolt_y0 <= y <= bolt_y1:
                # Bóng tia sét (nằm gọn trong thân pin).
                dsh = sd_polygon(x, y, bolt_shadow)
                if dsh > -1.5 and dbody < -2.0:
                    r, g, b = mix((r, g, b), (4, 40, 28), clamp01(0.5 + dsh) * 0.30)
                # Tia sét (màu nền, cắt vào viên pin).
                dbolt = sd_polygon(x, y, BOLT)
                if dbolt > -1.5:
                    cov = clamp01(0.5 + dbolt)
                    r = r + (INK[0] - r) * cov
                    g = g + (INK[1] - g) * cov
                    b = b + (INK[2] - b) * cov

            # Cực pin (nub) màu xanh dương.
            dt = sd_round_rect(x, y, tcx, tcy, thw, thh, trad)
            if dt < 1.5:
                cov = clamp01(0.5 - dt)
                t = clamp01((y - (tcy - thh)) / (2.0 * thh))
                col = mix(BLUE_TOP, BLUE_BOTTOM, t ** 0.85)
                r = r + (col[0] - r) * cov
                g = g + (col[1] - g) * cov
                b = b + (col[2] - b) * cov

            row += bytes((
                int(clamp01(r / 255.0) * 255.0 + 0.5),
                int(clamp01(g / 255.0) * 255.0 + 0.5),
                int(clamp01(b / 255.0) * 255.0 + 0.5),
            ))
        rows.append(row)
    return rows


def write_png(path: Path, rows: list[bytearray]) -> None:
    w, h = SIZE, SIZE
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main() -> None:
    write_png(OUT, render())
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
