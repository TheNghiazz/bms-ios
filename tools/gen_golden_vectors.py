#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sinh file golden_vectors.json từ bộ giải mã gốc (Python desktop).

Cách chạy:
    python gen_golden_vectors.py

File reference/guniversal_bms_ble_reader.py là BẢN COPY của file gốc
(thư viện duy nhất bị dùng là struct/datetime, không cần bleak).
Script này "tự kiểm" mọi case trước khi ghi: giải mã lại bằng chính
parser gốc và assert các giá trị đáng ngờ để đảm bảo file JSON đúng.
"""

from __future__ import annotations

import importlib.util
import json
import os
import struct
import sys
from collections.abc import Callable
from dataclasses import asdict

HERE = os.path.dirname(os.path.abspath(__file__))
REF_PATH = os.path.join(HERE, "reference", "universal_bms_ble_reader.py")
OUT_PATH = os.path.join(HERE, "..", "Sources", "BMSCore", "Resources", "golden_vectors.json")

# Console Windows thường là cp1252 -> bật UTF-8 để in tiếng Việt
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# ------------------------------------------------------------------ import ---
spec = importlib.util.spec_from_file_location("bms_reader", REF_PATH)
mod = importlib.util.module_from_spec(spec)
sys.modules["bms_reader"] = mod          # cần cho dataclass khi import bằng đường dẫn
spec.loader.exec_module(mod)

HEADER_JK_RESP = mod.HEADER_JK_RESP
HEADER_JK_CMD = mod.HEADER_JK_CMD
HEADER_ANT_RESP = mod.HEADER_ANT_RESP


def snake_to_camel(s: str) -> str:
    parts = s.split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


def camel_dict(d):
    """Chuyển toàn bộ key snake_case -> camelCase để khớp struct Swift."""
    return {snake_to_camel(k): v for k, v in asdict(d).items()}


def snapshot(parser) -> dict:
    """Trạng thái đầy đủ sau khi feed xong để Swift so khớp."""
    return {
        "brand": parser.bms_brand,
        "hasCellInfo": parser.has_cell_info,
        "hasDeviceInfo": parser.has_device_info,
        "hasSettingsInfo": parser.has_settings_info,
        "live": camel_dict(parser.live),
        "deviceInfo": camel_dict(parser.device_info),
        "settingsInfo": camel_dict(parser.settings_info),
    }


CASES: list[dict] = []


def drain(parser) -> None:
    """
    Bản gốc gọi `return` ngay sau khi decode frame ĐẦU TIÊN trong buffer,
    bỏ thừa các frame kế tiếp (chỉ được decode ở lần gọi feed sau).
    Swift sẽ xử lý HẾT buffer mỗi lần nhận (cải tiến có chủ đích, xem
    docs/protocol.md). Bước drain mô phỏng: giữ gọi feed(b'') tới khi
    không còn frame nào còn dư.
    """
    for _ in range(64):
        if parser.feed_notification(b"") is None:
            return


CASES: list[dict] = []


def add_case(name: str, frames: list[bytes], description: str = "") -> None:
    ways = {}
    # Chế độ 1: mỗi frame là một lần feed riêng (giống GUI gốc)
    p = mod.UniversalBmsParser(mode="auto")
    for f in frames:
        p.feed_notification(f)
        drain(p)
    ways["separate"] = snapshot(p)

    # Chế độ 2: glue các frame thành một dòng byte, chia thành chunk
    # ngẫu nhiên tăng dần 1,3,7,13,20,64,182 rồi feed - kết quả phải giống.
    joined = b"".join(frames)
    offs, i, k = [0], 0, 0
    while i < len(joined):
        i += min([1, 3, 7, 13, 20, 64, 182][k % 7], len(joined) - i)
        offs.append(i)
        k += 1
    chunks = [joined[a:b] for a, b in zip(offs, offs[1:])]
    p2 = mod.UniversalBmsParser(mode="auto")
    for c in chunks:
        p2.feed_notification(c)
        drain(p2)
    ways["chunked"] = snapshot(p2)

    if ways["separate"] != ways["chunked"]:
        raise RuntimeError(
            f"Case {name}: kết quả 'separate' khác 'chunked'!\n"
        )

    CASES.append(
        {
            "name": name,
            "description": description,
            "frames": [f.hex() for f in frames],
            "expect": ways["separate"],
        }
    )
    # In tóm tắt cho người xem
    live = ways["separate"]["live"]
    print(
        f"[ok] {name}: brand={ways['separate']['brand']} "
        f"V={live['totalVoltageV']} A={live['currentA']} "
        f"SOC={live['socPercent']}% cells={live['activeCellCount']}"
    )


# --------------------------------------------------------------- builders ---
def set_str(buf: bytearray, start: int, end: int, text: str) -> None:
    """Ghi chuỗi ASCII vào buf[start:end], đệm \\0 đủ độ dài.

    LƯU Ý: bản gốc của file universal_bms_ble_reader.py gán chuỗi ngắn
    vào slice (vd f_dev[6:22] = b"...\\x00") làm bytearray CO LẠI, gây
    IndexError ở dòng f_dev[299]. Đây là một trong các bug của bản gốc
    (đã ghi trong docs/protocol.md). Hàm này tránh hoàn toàn lỗi đó.
    """
    raw = text.encode("ascii")
    length = end - start
    if len(raw) > length:
        raise ValueError(f"Chuỗi {text!r} dài hơn ô {start}:{end}")
    buf[start:end] = raw + b"\x00" * (length - len(raw))


def mk_jk_device_info_24s() -> bytes:
    """Frame 0x03 (device info) của JK 24S - khớp offsets của decode_jk_frame."""
    f = bytearray(300)
    f[0:4] = HEADER_JK_RESP
    f[4] = 0x03
    set_str(f, 6, 22, "JK-B2A20S20P")      # vendor
    set_str(f, 22, 30, "10.XW")            # hw
    set_str(f, 30, 38, "10.08")            # sw -> nhánh JK02_24S
    struct.pack_into("<I", f, 38, 172800)
    struct.pack_into("<I", f, 42, 16)
    set_str(f, 46, 62, "JK_EV_60V30AH")
    set_str(f, 62, 78, "1234")
    set_str(f, 78, 86, "250918")
    set_str(f, 86, 97, "4012889012")
    set_str(f, 97, 102, "0000")
    set_str(f, 102, 118, "user123")
    set_str(f, 118, 134, "123456")
    f[299] = mod.calc_crc8(f[:299])
    return bytes(f)


def mk_jk_settings_24s() -> bytes:
    """Frame 0x01 (settings) của JK 24S - khớp decode khung 0x01."""
    f = bytearray(300)
    f[0:4] = HEADER_JK_RESP
    f[4] = 0x01
    struct.pack_into("<I", f, 10, 2800)    # UVP 2.80 V
    struct.pack_into("<I", f, 18, 4200)    # OVP 4.20 V
    struct.pack_into("<I", f, 26, 8)       # 8 mV trigger cân bằng
    struct.pack_into("<I", f, 50, 15000)   # sạc tối đa 15 A
    struct.pack_into("<I", f, 62, 60000)   # xả tối đa 60 A
    struct.pack_into("<I", f, 78, 2000)    # cân bằng 2 A
    f[114] = 17                            # 17 cell
    f[118] = 1
    f[122] = 1
    f[126] = 1
    struct.pack_into("<I", f, 130, 30000)  # 30 Ah
    f[299] = mod.calc_crc8(f[:299])
    return bytes(f)


def mk_jk_cells_24s() -> bytes:
    """Frame 0x02 (cell info) của JK 24S (17 cell même demo gốc)."""
    f = bytearray(300)
    f[0:4] = HEADER_JK_RESP
    f[4] = 0x02
    mv_list = [3821, 3820, 3822, 3819, 3820, 3823, 3820, 3818, 3821, 3820,
               3822, 3820, 3819, 3821, 3824, 3820, 3821]
    for i, mv in enumerate(mv_list):
        struct.pack_into("<H", f, 6 + i * 2, mv)         # mV (LE)
        struct.pack_into("<H", f, 64 + i * 2, 41 + (i % 5))  # mOhm (mΩ)
    struct.pack_into("<I", f, 118, sum(mv_list))   # tổng ~64.951 V
    struct.pack_into("<i", f, 126, -12500)         # -12.5 A
    struct.pack_into("<h", f, 130, 312)            # T1 31.2°C
    struct.pack_into("<h", f, 132, 318)            # T2 31.8°C
    struct.pack_into("<h", f, 134, 365)            # MOS 36.5°C
    f[140] = 0                                     # idle
    f[141] = 78                                    # SOC 78%
    struct.pack_into("<I", f, 142, 23400)          # còn 23.4 Ah
    struct.pack_into("<I", f, 146, 30000)          # danh định 30 Ah
    struct.pack_into("<I", f, 150, 42)             # chu kỳ
    struct.pack_into("<I", f, 154, 186000)
    f[158] = 99                                    # SOH
    struct.pack_into("<I", f, 162, 123456)         # runtime
    f[166] = 1                                     # MOS sạc ON
    f[167] = 1                                     # MOS xả ON
    f[299] = mod.calc_crc8(f[:299])
    return bytes(f)


def jk_cmd(cmd: int, counter: int = 1) -> bytes:
    """Khung lệnh JK 20 byte (dùng để nhét vào 'commands' nếu cần)."""
    return mod.build_jk_command_frame(cmd, counter)


def mk_jk_device_info_32s() -> bytes:
    """Frame 0x03 của JK với SW 11.08 -> được nhận diện là JK02_32S."""
    f = bytearray(300)
    f[0:4] = HEADER_JK_RESP
    f[4] = 0x03
    set_str(f, 6, 22, "JK-B2A32S15P")
    set_str(f, 22, 30, "12.XW")
    set_str(f, 30, 38, "11.08")
    struct.pack_into("<I", f, 38, 90000)      # uptime 25h
    struct.pack_into("<I", f, 42, 20)
    set_str(f, 46, 62, "JK_STATION_32S")
    set_str(f, 62, 78, "5678")
    set_str(f, 78, 86, "260314")              # 2026-03-14
    set_str(f, 86, 97, "4012889012")
    set_str(f, 97, 102, "0000")
    set_str(f, 102, 118, "user123")
    set_str(f, 118, 134, "123456")
    f[299] = mod.calc_crc8(f[:299])
    return bytes(f)


def mk_jk_cells_32s() -> bytes:
    """
    Frame 0x02 của JK02_32S: 32 cell, offset2 = +32.
    Offsets đã đối chiếu với decode_jk_frame:
      cells 6+i*2, resistances 64+16+i*2, mos 112+32, total 118+32,
      current 126+32, T1/T2 162/164, err 134+32, balance 138+32,
      action 140+32, soc 141+32, remain 142+32, nom 146+32,
      cycles 150+32, totalcap 154+32, soh 158+32, runtime 162+32,
      mos flags 166/167/168+32.
    """
    f = bytearray(300)
    f[0:4] = HEADER_JK_RESP
    f[4] = 0x02
    mv = [3596 + (i % 5) for i in range(32)]      # 3.596-3.600 V
    for i, v in enumerate(mv):
        struct.pack_into("<H", f, 6 + i * 2, v)
        struct.pack_into("<H", f, 80 + i * 2, 35 + (i % 8))   # 0.035-0.042 Ohm
    struct.pack_into("<h", f, 144, 378)          # MOS 37.8°C
    struct.pack_into("<I", f, 150, sum(mv))      # 115.144 V tổng
    struct.pack_into("<i", f, 158, -8000)        # -8.0 A (xả)
    struct.pack_into("<h", f, 162, 352)          # T1 35.2
    struct.pack_into("<h", f, 164, 355)          # T2 35.5
    struct.pack_into("<I", f, 166, 1 << 5)       # lỗi bit 5 (Pack OVP)
    struct.pack_into("<h", f, 170, 1200)         # dòng cân bằng 1.2 A
    f[172] = 1                                   # CB Nạp
    f[173] = 64                                  # SOC 64%
    struct.pack_into("<I", f, 174, 32000)        # 32.0 Ah còn lại
    struct.pack_into("<I", f, 178, 50000)        # 50.0 Ah danh định
    struct.pack_into("<I", f, 182, 55)           # chu kỳ
    struct.pack_into("<I", f, 186, 2750000)
    f[190] = 98
    struct.pack_into("<I", f, 194, 4320)         # 1h12m
    f[198] = 1
    f[199] = 1
    f[200] = 0
    f[299] = mod.calc_crc8(f[:299])
    return bytes(f)


def mk_jbd_basic() -> bytes:
    """
    Khung JBD 0x03: DD 03 00 <len> ... 77
    decode_jbd_frame đọc: total@4 u16BE*x0.01, current@6 i16BE*x0.01,
    remain@8, nominal@10, cycles@12, soc@data[23], mos@data[24].
    Chọn len=27 để data[23]/[24] nằm trong frame.
    """
    data_len = 27
    f = bytearray(7 + data_len)
    f[0] = 0xDD
    f[1] = 0x03
    f[2] = 0x00
    f[3] = data_len
    struct.pack_into(">H", f, 4, 6530)    # 65.30 V
    struct.pack_into(">h", f, 6, -1200)   # -12.00 A (xả)
    struct.pack_into(">H", f, 8, 1800)    # 18.00 Ah
    struct.pack_into(">H", f, 10, 3000)   # 30.00 Ah
    struct.pack_into(">H", f, 12, 38)     # 38 chu kỳ
    f[23] = 78                            # SOC 78%
    f[24] = 0x03                          # MOS sạc + xả bật
    f[-1] = 0x77
    return bytes(f)


def mk_jbd_cells() -> bytes:
    """Khung JBD 0x04: DD 04 00 <len> ... 77, len = 2*số cell."""
    n = 17
    data_len = 2 * n
    f = bytearray(7 + data_len)
    f[0] = 0xDD
    f[1] = 0x04
    f[2] = 0x00
    f[3] = data_len
    for i in range(n):
        struct.pack_into(">H", f, 4 + i * 2, 3588 + (i % 4))
    f[-1] = 0x77
    return bytes(f)


def mk_daly_0x90(total_v10: int = 608, raw_current: int = 30500, soc10: int = 780) -> bytes:
    """
    Daly 13 byte: decode_daly_frame đọc cmd=data[2]==0x90:
      total=(d4<<8|d5)*0.1 ; current=((d8<<8|d9)-30000)*0.1 ; soc=((d10<<8|d11))*0.1
      checksum = sum(d[0..11]) & 0xFF tại d[12].
    """
    f = bytearray(13)
    f[0] = 0xA5
    f[1] = 0x01
    f[2] = 0x90
    f[3] = 0x08
    f[4] = (total_v10 >> 8) & 0xFF
    f[5] = total_v10 & 0xFF
    f[6] = 0x14
    f[7] = 0x28
    f[8] = (raw_current >> 8) & 0xFF
    f[9] = raw_current & 0xFF
    f[10] = (soc10 >> 8) & 0xFF
    f[11] = soc10 & 0xFF
    f[12] = sum(f[:12]) & 0xFF
    return bytes(f)


# ------------------------------------------------------------------ cases ---
add_case(
    "ant_17s_demo",
    [mod.build_demo_ant_60v30ah()],
    "Mẫu ANT-BMS 17S 60V 30Ah dựng sẵn trong code gốc.",
)

d_dev = mk_jk_device_info_24s()
d_set = mk_jk_settings_24s()
d_cell = mk_jk_cells_24s()
add_case(
    "jk_24s_demo",
    [d_dev, d_set, d_cell],
    "Mẫu JK-BMS 24S 17 cell (SW 10.08 -> nhánh 24S).",
)

add_case(
    "jk_32s_synthetic",
    [mk_jk_device_info_32s(), mk_jk_cells_32s()],
    "JD 32S tổng hợp: feed 0x03 TRƯỚC 0x02 để is_32s=True; "
    "cảnh báo: nếu 0x02 đến trước thì parser gốc (và port Swift) "
    "đành decode theo 24S - đã ghi ở docs/protocol.md.",
)

add_case(
    "jbd_basic_and_cells",
    [mk_jbd_basic(), mk_jbd_cells()],
    "JBD/Xiaoxiang: khung 0x03 (điện áp/dòng/dung lượng) và 0x04 (cell).",
)

add_case(
    "daly_0x90",
    [mk_daly_0x90()],
    "Daly BMS: khung 0x90 có checksum đúng.",
)

# --- ca lỗi: sai CRC JK
bad = bytearray(d_cell)
bad[299] = (bad[299] + 1) & 0xFF
add_case(
    "jk_bad_crc_rejected",
    [bytes(bad)],
    "CRC sai -> pop(0), không decode gì; brand vẫn mặc định.",
)

# --- ca lỗi: rác phía trước rồi tới ANT hoàn chỉnh
junk = b"\x01\x02\x03\x7e\x11\x22\x33\x44"   # không chứa 55/AA/DD/A5
add_case(
    "junk_prefix_then_ant",
    [junk + mod.build_demo_ant_60v30ah()],
    "Byte rác đằng trước -> resync -> vẫn decode ANT bù.",
)

# --- ca lỗi: 2 frame JBD dính liền
add_case(
    "jbd_glued",
    [mk_jbd_basic() + mk_jbd_cells()],
    "Hai khung JBD nằm trong MỘT notification - phải decode cả hai.",
)

# Ca 32S feed NGƯỢC thứ tự (bug gốc được khoá lại trong golden test):
p = mod.UniversalBmsParser(mode="auto")
p.feed_notification(mk_jk_cells_32s())
p.feed_notification(mk_jk_device_info_32s())
drain(p)
CASES.append(
    {
        "name": "jk_32s_cells_first",
        "description": "Khoá hành vi gốc: 0x02 đến trước 0x03 -> cells "
        "vẫn decode theo nhánh 24S (protocol đổi sau nhưng không "
        "decode lại). Swift phải khớp đúng như vậy.",
        "frames": [mk_jk_cells_32s().hex(), mk_jk_device_info_32s().hex()],
        "expect": snapshot(p),
    }
)
print(f"[ok] jk_32s_cells_first: brand={p.bms_brand} V={p.live.total_voltage_v} "
      f"cells={p.live.active_cell_count} (khoá hành vi gốc)")

# -------------------------------------------------------- ghi & tự kiểm ----
os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
payload = {"version": 1, "cases": CASES}
with open(OUT_PATH, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)

print(f"\nGhi {len(CASES)} case -> {os.path.abspath(OUT_PATH)} "
      f"({os.path.getsize(OUT_PATH)} bytes)")

# Tự kiểm lần cuối bằng CLI --demo của bản gốc (bảo đảm module import được)
sys.stderr.write("Hoàn tất.\n")
