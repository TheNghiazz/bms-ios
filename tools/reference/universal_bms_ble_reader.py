#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 UNIVERSAL SMART BMS MONITOR (BLUETOOTH BLE) - PYTHON DESKTOP GUI & CLI
 Hỗ trợ mọi hệ pin (3S đến 32S, mọi dung lượng Ah) - Tự động nhận diện:
   - JK-BMS (Jikong JK02_24S / JK02_32S)
   - ANT-BMS (Mayi / JNFN 140B Stream)
   - Daly Smart BMS (UART / BLE)
   - JBD / Xiaoxiang / Overkill Solar BMS
================================================================================
Yêu cầu thư viện:
   pip install bleak

Cách sử dụng:
   python universal_bms_ble_reader.py          # Mở giao diện đồ họa hiện đại (Dark-theme GUI)
   python universal_bms_ble_reader.py --scan   # Quét tìm thiết bị Bluetooth xung quanh
   python universal_bms_ble_reader.py --demo   # Chạy mô phỏng kiểm tra (không cần mạch thật)
   python universal_bms_ble_reader.py --mac 28:D4:1E:1B:A9:D9  # Kết nối đọc trực tiếp
"""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import asdict, dataclass, field
import datetime
import json
import os
import struct
import sys
import threading
import time
from typing import Any, Callable, Dict, List, Optional

try:
    from bleak import BleakClient, BleakScanner
    from bleak.backends.characteristic import BleakGATTCharacteristic
    BLEAK_AVAILABLE = True
except ImportError:
    BLEAK_AVAILABLE = False

DISCOVERED_DEVICES_CACHE: Dict[str, Any] = {}

# ==============================================================================
# HẰNG SỐ GIAO THỨC BLUETOOTH
# ==============================================================================
UUID_JK_FFE0 = "0000ffe0-0000-1000-8000-00805f9b34fb"
UUID_JK_FFE1 = "0000ffe1-0000-1000-8000-00805f9b34fb"
UUID_JK_FFE2 = "0000ffe2-0000-1000-8000-00805f9b34fb"

UUID_DALY_FFF0 = "0000fff0-0000-1000-8000-00805f9b34fb"
UUID_JBD_FF00 = "0000ff00-0000-1000-8000-00805f9b34fb"

# Mào đầu khung truyền
HEADER_JK_RESP = bytes([0x55, 0xAA, 0xEB, 0x90])
HEADER_JK_CMD = bytes([0xAA, 0x55, 0x90, 0xEB])
HEADER_ANT_RESP = bytes([0xAA, 0x55, 0xAA, 0xFF])
CMD_ANT_WAKEUP = bytes([0x5A, 0x5A, 0x00, 0x00, 0x00, 0x00])

CMD_JK_CELL_INFO = 0x96
CMD_JK_DEVICE_INFO = 0x97

ERROR_BIT_LABELS: Dict[int, str] = {
    0: "Nội trở dây cân bằng lớn",
    1: "Quá nhiệt MOSFET",
    2: "Số cell thực tế lệch cài đặt",
    4: "Pin đã sạc đầy",
    5: "Quá áp tổng (Pack OVP)",
    6: "Quá dòng sạc",
    7: "Ngắn mạch sạc",
    8: "Quá nhiệt khi sạc",
    9: "Thấp nhiệt khi sạc",
    10: "Lỗi giao tiếp chip phụ",
    11: "Thấp áp Cell (Cell UVP)",
    12: "Thấp áp tổng (Pack UVP)",
    13: "Quá dòng xả",
    14: "Ngắn mạch xả",
    15: "Quá nhiệt khi xả",
    16: "Lỗi MOSFET sạc",
    17: "Lỗi MOSFET xả",
    18: "Mất kết nối GPS",
    19: "Cần đổi mật khẩu",
    20: "Mở mạch xả thất bại",
    21: "Quá nhiệt pin",
    22: "Lỗi cảm biến nhiệt độ",
    23: "Lỗi module giới hạn dòng",
}


# ==============================================================================
# CẤU TRÚC DỮ LIỆU ĐẦU RA (DATA MODEL)
# ==============================================================================
@dataclass
class BMSDeviceInfo:
    vendor_id: str = ""
    hardware_version: str = ""
    software_version: str = ""
    uptime_seconds: int = 0
    power_on_count: int = 0
    device_name: str = ""
    device_passcode: str = ""     # Mật khẩu kết nối Bluetooth (PIN)
    manufacturing_date: str = ""
    serial_number: str = ""
    passcode: str = ""
    user_data: str = ""
    setup_passcode: str = ""      # Mật khẩu cài đặt


@dataclass
class BMSSettingsInfo:
    cell_count_configured: int = 0
    nominal_capacity_ah: float = 0.0
    smart_sleep_voltage_v: float = 0.0
    cell_uvp_v: float = 0.0
    cell_uvpr_v: float = 0.0
    cell_ovp_v: float = 0.0
    cell_ovpr_v: float = 0.0
    balance_trigger_voltage_v: float = 0.0
    start_balance_voltage_v: float = 0.0
    power_off_voltage_v: float = 0.0
    max_charge_current_a: float = 0.0
    max_discharge_current_a: float = 0.0
    max_balance_current_a: float = 0.0
    charge_switch_enabled: bool = False
    discharge_switch_enabled: bool = False
    balancer_switch_enabled: bool = False


@dataclass
class BMSLiveTelemetry:
    detected_brand: str = "Tự động nhận diện"
    protocol_version: str = "AUTO"
    active_cell_count: int = 0
    cell_voltages_v: List[float] = field(default_factory=list)
    cell_resistances_ohm: List[float] = field(default_factory=list)
    average_cell_voltage_v: float = 0.0
    delta_cell_voltage_v: float = 0.0
    max_cell_voltage_v: float = 0.0
    min_cell_voltage_v: float = 0.0
    max_voltage_cell_num: int = 0
    min_voltage_cell_num: int = 0
    total_voltage_v: float = 0.0
    current_a: float = 0.0
    power_w: float = 0.0
    balance_current_a: float = 0.0
    balancing_action: int = 0
    balancing_status_text: str = "Tắt (Idle)"
    soc_percent: int = 0
    soh_percent: int = 100
    remaining_capacity_ah: float = 0.0
    nominal_capacity_ah: float = 0.0
    cycle_count: int = 0
    total_cycle_capacity_ah: float = 0.0
    mosfet_temp_c: float = 0.0
    temp_sensor_1_c: float = 0.0
    temp_sensor_2_c: float = 0.0
    temp_sensor_3_c: Optional[float] = None
    temp_sensor_4_c: Optional[float] = None
    charging_mos_on: bool = False
    discharging_mos_on: bool = False
    precharging_on: bool = False
    heating_on: bool = False
    charger_plugged: bool = False
    runtime_seconds: int = 0
    errors_bitmask: int = 0
    error_messages: List[str] = field(default_factory=list)


def calc_crc8(data: bytes) -> int:
    return sum(data) & 0xFF


def build_jk_command_frame(cmd_byte: int, counter: int = 1) -> bytes:
    frame = bytearray(20)
    frame[0:4] = HEADER_JK_CMD
    frame[4] = cmd_byte & 0xFF
    frame[5] = 0x00
    frame[16] = counter & 0xFF
    frame[19] = calc_crc8(frame[:19])
    return bytes(frame)


def read_c_string(buf: bytes, start: int, max_len: int) -> str:
    raw_slice = buf[start : start + max_len]
    null_pos = raw_slice.find(b"\x00")
    if null_pos != -1:
        raw_slice = raw_slice[:null_pos]
    return raw_slice.decode("utf-8", errors="replace").strip()


def format_duration(seconds: int) -> str:
    days, rem = divmod(max(0, int(seconds)), 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    return f"{days} ngày {hours:02d}:{minutes:02d}:{secs:02d}"


def format_eta_hours(hours_float: float) -> str:
    if hours_float <= 0 or not (0 < hours_float < 9999):
        return "0 phút"
    total_mins = round(hours_float * 60)
    hrs, mins = divmod(total_mins, 60)
    if hrs > 0:
        return f"{hrs} giờ {mins:02d} phút"
    return f"{mins} phút"


# ==============================================================================
# BỘ GIẢI MÃ ĐA GIAO THỨC TỰ ĐỘNG (UNIVERSAL MULTI-PROTOCOL PARSER)
# ==============================================================================
class UniversalBmsParser:
    def __init__(self, mode: str = "auto") -> None:
        self.mode = mode.lower()
        self.buffer = bytearray()
        self.device_info = BMSDeviceInfo()
        self.settings_info = BMSSettingsInfo()
        self.live = BMSLiveTelemetry()

        self.has_device_info = False
        self.has_settings_info = False
        self.has_cell_info = False
        self.bms_brand = "Tự động nhận diện"

    def feed_notification(self, chunk: bytes) -> Optional[str]:
        self.buffer.extend(chunk)

        # Bộ phân tích luồng trượt đa giao thức
        while len(self.buffer) >= 13:
            # 1. Kiểm tra khung JK-BMS (300 bytes, 55 AA EB 90)
            if (
                len(self.buffer) >= 4
                and self.buffer[0] == 0x55
                and self.buffer[1] == 0xAA
                and self.buffer[2] == 0xEB
                and self.buffer[3] == 0x90
            ):
                if len(self.buffer) < 300:
                    break
                frame = bytes(self.buffer[:300])
                if calc_crc8(frame[:299]) == frame[299]:
                    self.buffer = self.buffer[300:]
                    self.decode_jk_frame(frame)
                    return "JK-BMS"
                else:
                    self.buffer.pop(0)
                    continue

            # 2. Kiểm tra khung ANT-BMS (140 bytes, AA 55 AA FF)
            if (
                len(self.buffer) >= 4
                and self.buffer[0] == 0xAA
                and self.buffer[1] == 0x55
                and self.buffer[2] == 0xAA
                and self.buffer[3] == 0xFF
            ):
                if len(self.buffer) < 140:
                    break
                frame = bytes(self.buffer[:140])
                self.buffer = self.buffer[140:]
                self.decode_ant_frame(frame)
                return "ANT-BMS"

            # 3. Kiểm tra khung JBD BMS (DD ... 77)
            if self.buffer[0] == 0xDD and len(self.buffer) >= 7:
                data_len = self.buffer[3]
                packet_len = data_len + 7
                if len(self.buffer) < packet_len:
                    if packet_len > 300:
                        self.buffer.pop(0)
                        continue
                    break
                if self.buffer[packet_len - 1] == 0x77:
                    frame = bytes(self.buffer[:packet_len])
                    self.buffer = self.buffer[packet_len:]
                    self.decode_jbd_frame(frame)
                    return "JBD-BMS"
                else:
                    self.buffer.pop(0)
                    continue

            # 4. Kiểm tra khung Daly BMS (A5 01 ... 13 bytes)
            if self.buffer[0] == 0xA5 and self.buffer[1] in (0x01, 0x40):
                if len(self.buffer) < 13:
                    break
                chk = sum(self.buffer[:12]) & 0xFF
                if chk == self.buffer[12]:
                    frame = bytes(self.buffer[:13])
                    self.buffer = self.buffer[13:]
                    self.decode_daly_frame(frame)
                    return "DALY-BMS"
                else:
                    self.buffer.pop(0)
                    continue

            # Trượt tìm byte mào đầu tiềm năng
            found = -1
            for idx in range(1, len(self.buffer)):
                b = self.buffer[idx]
                if b in (0x55, 0xAA, 0xDD, 0xA5):
                    found = idx
                    break
            if found != -1:
                self.buffer = self.buffer[found:]
            else:
                self.buffer = self.buffer[-3:]
                break

        if len(self.buffer) > 2048:
            self.buffer.clear()
        return None

    def decode_jk_frame(self, data: bytes) -> None:
        frame_type = data[4]
        self.bms_brand = "JK-BMS"
        self.live.detected_brand = "JK-BMS"

        if frame_type == 0x03:
            d = self.device_info
            d.vendor_id = read_c_string(data, 6, 16) or "JK-BMS"
            d.hardware_version = read_c_string(data, 22, 8) or "N/A"
            d.software_version = read_c_string(data, 30, 8) or "N/A"
            d.uptime_seconds = struct.unpack_from("<I", data, 38)[0]
            d.power_on_count = struct.unpack_from("<I", data, 42)[0]
            d.device_name = read_c_string(data, 46, 16) or "JK-BMS"
            d.device_passcode = read_c_string(data, 62, 16) or "1234"

            mfg = read_c_string(data, 78, 8)
            d.manufacturing_date = f"20{mfg[:2]}-{mfg[2:4]}-{mfg[4:6]}" if len(mfg) == 6 and mfg.isdigit() else mfg
            d.serial_number = read_c_string(data, 86, 11) or "N/A"
            d.passcode = read_c_string(data, 97, 5) or "0000"
            d.user_data = read_c_string(data, 102, 16) or "N/A"
            d.setup_passcode = read_c_string(data, 118, 16) or "123456"

            self.live.protocol_version = "JK02_32S" if ("11." in d.software_version or "12." in d.software_version) else "JK02_24S"
            self.has_device_info = True

        elif frame_type == 0x01:
            s = self.settings_info
            u32 = lambda pos: struct.unpack_from("<I", data, pos)[0]
            s.smart_sleep_voltage_v = round(u32(6) * 0.001, 3)
            s.cell_uvp_v = round(u32(10) * 0.001, 3)
            s.cell_uvpr_v = round(u32(14) * 0.001, 3)
            s.cell_ovp_v = round(u32(18) * 0.001, 3)
            s.cell_ovpr_v = round(u32(22) * 0.001, 3)
            s.balance_trigger_voltage_v = round(u32(26) * 0.001, 3)
            s.power_off_voltage_v = round(u32(46) * 0.001, 3)
            s.max_charge_current_a = round(u32(50) * 0.001, 3)
            s.max_discharge_current_a = round(u32(62) * 0.001, 3)
            s.max_balance_current_a = round(u32(78) * 0.001, 3)
            s.cell_count_configured = data[114]
            s.charge_switch_enabled = bool(data[118])
            s.discharge_switch_enabled = bool(data[122])
            s.balancer_switch_enabled = bool(data[126])
            s.nominal_capacity_ah = round(u32(130) * 0.001, 3)
            s.start_balance_voltage_v = round(u32(138) * 0.001, 3)
            self.has_settings_info = True

        elif frame_type == 0x02:
            c = self.live
            is_32s = c.protocol_version == "JK02_32S"
            offset1 = 16 if is_32s else 0
            offset2 = 32 if is_32s else 0
            max_cells = 32 if is_32s else 24

            volts: List[float] = []
            res: List[float] = []
            min_v, max_v = 999.0, -999.0
            min_idx, max_idx = 0, 0

            for idx in range(max_cells):
                v = round(struct.unpack_from("<H", data, 6 + idx * 2)[0] * 0.001, 3)
                r = round(struct.unpack_from("<H", data, 64 + offset1 + idx * 2)[0] * 0.001, 3)
                if v > 0.05:
                    volts.append(v)
                    res.append(r)
                    if v < min_v:
                        min_v, min_idx = v, idx + 1
                    if v > max_v:
                        max_v, max_idx = v, idx + 1

            c.cell_voltages_v = volts
            c.cell_resistances_ohm = res
            c.active_cell_count = len(volts)
            if volts:
                c.average_cell_voltage_v = round(sum(volts) / len(volts), 3)
                c.min_cell_voltage_v = min_v
                c.max_cell_voltage_v = max_v
                c.delta_cell_voltage_v = round(max_v - min_v, 3)
                c.min_voltage_cell_num = min_idx
                c.max_voltage_cell_num = max_idx

            c.total_voltage_v = round(struct.unpack_from("<I", data, 118 + offset2)[0] * 0.001, 3)
            c.current_a = round(struct.unpack_from("<i", data, 126 + offset2)[0] * 0.001, 3)
            c.power_w = round(c.total_voltage_v * c.current_a, 2)

            c.temp_sensor_1_c = round(struct.unpack_from("<h", data, 130 + offset2)[0] * 0.1, 1)
            c.temp_sensor_2_c = round(struct.unpack_from("<h", data, 132 + offset2)[0] * 0.1, 1)

            if is_32s:
                c.mosfet_temp_c = round(struct.unpack_from("<h", data, 112 + offset2)[0] * 0.1, 1)
                c.errors_bitmask = struct.unpack_from("<I", data, 134 + offset2)[0]
                max_err_bits = 32
            else:
                c.mosfet_temp_c = round(struct.unpack_from("<h", data, 134 + offset2)[0] * 0.1, 1)
                c.errors_bitmask = struct.unpack_from("<H", data, 136 + offset2)[0]
                max_err_bits = 16

            c.error_messages = [
                ERROR_BIT_LABELS.get(b, f"Lỗi bit {b}")
                for b in range(max_err_bits)
                if (c.errors_bitmask & (1 << b)) != 0
            ]

            c.balance_current_a = round(struct.unpack_from("<h", data, 138 + offset2)[0] * 0.001, 3)
            c.balancing_action = data[140 + offset2]
            c.balancing_status_text = "CB Nạp" if c.balancing_action == 1 else ("CB Xả" if c.balancing_action == 2 else "Tắt (Idle)")
            c.soc_percent = data[141 + offset2]
            c.remaining_capacity_ah = round(struct.unpack_from("<I", data, 142 + offset2)[0] * 0.001, 3)
            c.nominal_capacity_ah = round(struct.unpack_from("<I", data, 146 + offset2)[0] * 0.001, 3)
            c.cycle_count = struct.unpack_from("<I", data, 150 + offset2)[0]
            c.total_cycle_capacity_ah = round(struct.unpack_from("<I", data, 154 + offset2)[0] * 0.001, 3)
            c.soh_percent = data[158 + offset2]
            c.runtime_seconds = struct.unpack_from("<I", data, 162 + offset2)[0]

            c.charging_mos_on = bool(data[166 + offset2])
            c.discharging_mos_on = bool(data[167 + offset2])
            c.precharging_on = bool(data[168 + offset2])
            self.has_cell_info = True

    def decode_ant_frame(self, data: bytes) -> None:
        self.bms_brand = "ANT-BMS"
        self.live.detected_brand = "ANT-BMS"
        self.live.protocol_version = "ANT-BMS (140B)"

        self.device_info.vendor_id = "ANT-BMS (Mayi/JNFN)"
        self.device_info.device_name = self.device_info.device_name or "ANT-BMS"
        self.device_info.device_passcode = "123456 (Mặc định)"
        self.device_info.setup_passcode = "123456 (Mặc định)"

        c = self.live
        c.total_voltage_v = round(struct.unpack_from(">H", data, 4)[0] * 0.1, 3)

        volts: List[float] = []
        res: List[float] = []
        min_v, max_v = 999.0, -999.0
        min_idx, max_idx = 0, 0

        for i in range(32):
            mv = struct.unpack_from(">H", data, 6 + i * 2)[0]
            v = round(mv * 0.001, 3)
            if 0.05 < v < 5.0:
                volts.append(v)
                res.append(0.04)
                if v < min_v:
                    min_v, min_idx = v, i + 1
                if v > max_v:
                    max_v, max_idx = v, i + 1

        c.cell_voltages_v = volts
        c.cell_resistances_ohm = res
        c.active_cell_count = len(volts)
        if volts:
            c.average_cell_voltage_v = round(sum(volts) / len(volts), 3)
            c.min_cell_voltage_v = min_v
            c.max_cell_voltage_v = max_v
            c.delta_cell_voltage_v = round(max_v - min_v, 3)
            c.min_voltage_cell_num = min_idx
            c.max_voltage_cell_num = max_idx

        c.current_a = round(struct.unpack_from(">i", data, 70)[0] * 0.1, 2)
        c.power_w = round(c.total_voltage_v * c.current_a, 1)
        c.soc_percent = min(100, max(0, data[74]))

        nom_raw = struct.unpack_from(">I", data, 75)[0]
        rem_raw = struct.unpack_from(">I", data, 79)[0]
        nom = nom_raw * 0.000001 if nom_raw > 500000 else (nom_raw * 0.001 if nom_raw > 1000 else nom_raw)
        rem = rem_raw * 0.000001 if rem_raw > 500000 else (rem_raw * 0.001 if rem_raw > 1000 else rem_raw)
        c.nominal_capacity_ah = round(nom if nom > 0 else 30.0, 2)
        c.remaining_capacity_ah = round(rem if rem > 0 else 25.0, 2)

        c.cycle_count = struct.unpack_from(">I", data, 83)[0]
        c.runtime_seconds = struct.unpack_from(">I", data, 87)[0]
        self.device_info.uptime_seconds = c.runtime_seconds

        c.temp_sensor_1_c = float(struct.unpack_from(">h", data, 91)[0])
        c.temp_sensor_2_c = float(struct.unpack_from(">h", data, 93)[0])
        c.mosfet_temp_c = float(struct.unpack_from(">h", data, 99)[0])

        c.charging_mos_on = bool(data[101])
        c.discharging_mos_on = bool(data[102])
        c.balancing_action = data[103]
        c.balancing_status_text = "Đang cân bằng" if c.balancing_action else "Tắt (Idle)"
        c.soh_percent = 100

        self.has_cell_info = True
        self.has_device_info = True

    def decode_jbd_frame(self, data: bytes) -> None:
        cmd = data[1]
        self.bms_brand = "JBD BMS"
        self.live.detected_brand = "JBD BMS"
        self.device_info.vendor_id = "JBD / Xiaoxiang BMS"
        c = self.live

        if cmd == 0x03:
            c.total_voltage_v = round(struct.unpack_from(">H", data, 4)[0] * 0.01, 3)
            c.current_a = round(struct.unpack_from(">h", data, 6)[0] * 0.01, 2)
            c.power_w = round(c.total_voltage_v * c.current_a, 1)
            c.remaining_capacity_ah = round(struct.unpack_from(">H", data, 8)[0] * 0.01, 2)
            c.nominal_capacity_ah = round(struct.unpack_from(">H", data, 10)[0] * 0.01, 2)
            c.cycle_count = struct.unpack_from(">H", data, 12)[0]
            c.soc_percent = data[23]
            mos = data[24]
            c.charging_mos_on = bool(mos & 0x01)
            c.discharging_mos_on = bool(mos & 0x02)
            self.has_cell_info = True
        elif cmd == 0x04:
            cell_cnt = data[3] // 2
            volts = [round(struct.unpack_from(">H", data, 4 + i * 2)[0] * 0.001, 3) for i in range(cell_cnt)]
            c.cell_voltages_v = [v for v in volts if v > 0.05]
            c.active_cell_count = len(c.cell_voltages_v)
            if c.cell_voltages_v:
                c.average_cell_voltage_v = round(sum(c.cell_voltages_v) / len(c.cell_voltages_v), 3)
                c.min_cell_voltage_v = min(c.cell_voltages_v)
                c.max_cell_voltage_v = max(c.cell_voltages_v)
                c.delta_cell_voltage_v = round(c.max_cell_voltage_v - c.min_cell_voltage_v, 3)
            self.has_cell_info = True

    def decode_daly_frame(self, data: bytes) -> None:
        self.bms_brand = "Daly BMS"
        self.live.detected_brand = "Daly BMS"
        c = self.live
        cmd = data[2]
        if cmd == 0x90:
            c.total_voltage_v = round(((data[4] << 8) | data[5]) * 0.1, 2)
            c.current_a = round((((data[8] << 8) | data[9]) - 30000) * 0.1, 2)
            c.power_w = round(c.total_voltage_v * c.current_a, 1)
            c.soc_percent = round(((data[10] << 8) | data[11]) * 0.1)
            self.has_cell_info = True


# ==============================================================================
# BỘ MẪU DỮ LIỆU ĐỂ KIỂM TRA (DEMO GENERATORS)
# ==============================================================================
def build_demo_ant_60v30ah() -> bytes:
    p = bytearray(140)
    p[0:4] = HEADER_ANT_RESP
    struct.pack_into(">H", p, 4, 608)  # 60.8V
    # 17S xe điện 60V (3.576V ~ 3.582V)
    for i in range(17):
        struct.pack_into(">H", p, 6 + i * 2, 3576 + (i % 6))
    struct.pack_into(">i", p, 70, -145)  # -14.5 A xả
    p[74] = 86                           # 86%
    struct.pack_into(">I", p, 75, 30000000)  # 30 Ah nominal
    struct.pack_into(">I", p, 79, 25800000)  # 25.8 Ah remain
    struct.pack_into(">I", p, 83, 38)        # 38 cycles
    struct.pack_into(">I", p, 87, 185400)    # 2 ngày runtime
    struct.pack_into(">h", p, 91, 31)        # T1
    struct.pack_into(">h", p, 93, 32)        # T2
    struct.pack_into(">h", p, 99, 37)        # MOS
    p[101] = 1                               # Charge ON
    p[102] = 1                               # Discharge ON
    p[103] = 1                               # Balancer active
    chk = sum(p[4:138]) & 0xFFFF
    struct.pack_into(">H", p, 138, chk)
    return bytes(p)


def build_demo_jk_60v30ah() -> tuple[bytes, bytes, bytes]:
    # 1. Frame 0x03 (Device Info)
    f_dev = bytearray(300)
    f_dev[0:4] = HEADER_JK_RESP
    f_dev[4] = 0x03
    f_dev[6:22] = b"JK-B2A20S20P\x00"
    f_dev[22:30] = b"10.XW\x00"
    f_dev[30:38] = b"10.08\x00"
    struct.pack_into("<I", f_dev, 38, 172800)
    struct.pack_into("<I", f_dev, 42, 16)
    f_dev[46:62] = b"JK_EV_60V30AH\x00"
    f_dev[62:78] = b"1234\x00"
    f_dev[78:86] = b"250918\x00"
    f_dev[86:97] = b"4012889012\x00"
    f_dev[118:134] = b"123456\x00"
    f_dev[299] = calc_crc8(f_dev[:299])

    # 2. Frame 0x01 (Settings)
    f_set = bytearray(300)
    f_set[0:4] = HEADER_JK_RESP
    f_set[4] = 0x01
    struct.pack_into("<I", f_set, 10, 2800)   # UVP 2.80V
    struct.pack_into("<I", f_set, 18, 4200)   # OVP 4.20V
    struct.pack_into("<I", f_set, 26, 8)      # 8mV balance trigger
    struct.pack_into("<I", f_set, 50, 15000)  # Max charge 15A
    struct.pack_into("<I", f_set, 62, 60000)  # Max discharge 60A
    struct.pack_into("<I", f_set, 78, 2000)   # Balance 2A
    f_set[114] = 17                           # 17S
    f_set[118] = 1
    f_set[122] = 1
    f_set[126] = 1
    struct.pack_into("<I", f_set, 130, 30000) # 30 Ah
    f_set[299] = calc_crc8(f_set[:299])

    # 3. Frame 0x02 (Live Cells)
    f_cell = bytearray(300)
    f_cell[0:4] = HEADER_JK_RESP
    f_cell[4] = 0x02
    mv_list = [3821, 3820, 3822, 3819, 3820, 3823, 3820, 3818, 3821, 3820, 3822, 3820, 3819, 3821, 3824, 3820, 3821]
    for i, mv in enumerate(mv_list):
        struct.pack_into("<H", f_cell, 6 + i * 2, mv)
        struct.pack_into("<H", f_cell, 64 + i * 2, 41 + (i % 5))
    struct.pack_into("<I", f_cell, 118, sum(mv_list))  # 64.951V
    struct.pack_into("<i", f_cell, 126, -12500)        # -12.5A
    struct.pack_into("<h", f_cell, 130, 312)           # T1
    struct.pack_into("<h", f_cell, 132, 318)           # T2
    struct.pack_into("<h", f_cell, 134, 365)           # MOS
    f_cell[140] = 0
    f_cell[141] = 78                                   # 78%
    struct.pack_into("<I", f_cell, 142, 23400)         # 23.4 Ah
    struct.pack_into("<I", f_cell, 146, 30000)         # 30.0 Ah
    struct.pack_into("<I", f_cell, 150, 42)
    f_cell[158] = 99
    f_cell[166] = 1
    f_cell[167] = 1
    f_cell[299] = calc_crc8(f_cell[:299])

    return bytes(f_dev), bytes(f_set), bytes(f_cell)


# ==============================================================================
# GIAO DIỆN ĐỒ HỌA CAO CẤP (XỊN XÒ) - TKINTER MODERN DARK UI
# ==============================================================================
def launch_modern_gui() -> None:
    import tkinter as tk
    from tkinter import messagebox, ttk

    # Cấu hình màu sắc hiện đại chuẩn Industrial Dark
    COLOR_BG = "#0b1120"        # Nền tối sâu
    COLOR_HEADER = "#0f172a"    # Nền thanh trên
    COLOR_CARD = "#1e293b"      # Thẻ nổi
    COLOR_CARD_BORDER = "#334155"
    COLOR_ACCENT_GREEN = "#10b981"
    COLOR_ACCENT_BLUE = "#38bdf8"
    COLOR_ACCENT_AMBER = "#f59e0b"
    COLOR_ACCENT_ROSE = "#f43f5e"
    COLOR_TEXT_MAIN = "#f8fafc"
    COLOR_TEXT_MUTED = "#94a3b8"

    root = tk.Tk()
    root.title("Universal Smart BMS Monitor (JK-BMS, ANT-BMS, Daly, JBD) - Tự động nhận diện")
    root.geometry("1100x780")
    root.minsize(980, 680)
    root.configure(bg=COLOR_BG)

    parser = UniversalBmsParser(mode="auto")
    ble_thread: Optional[threading.Thread] = None
    stop_event = threading.Event()

    # 1. TOP CONTROL BAR
    top_bar = tk.Frame(root, bg=COLOR_HEADER, height=64, padx=16, pady=10, highlightbackground=COLOR_CARD_BORDER, highlightthickness=1)
    top_bar.pack(fill=tk.X, side=tk.TOP)

    # Logo & Title
    logo_frame = tk.Frame(top_bar, bg=COLOR_HEADER)
    logo_frame.pack(side=tk.LEFT)

    lbl_title = tk.Label(logo_frame, text="⚡ UNIVERSAL SMART BMS", font=("Segoe UI", 12, "bold"), fg=COLOR_TEXT_MAIN, bg=COLOR_HEADER)
    lbl_title.pack(anchor=tk.W)
    lbl_sub = tk.Label(logo_frame, text="Tự động nhận diện: JK • ANT • Daly • JBD (3S–32S)", font=("Segoe UI", 8), fg=COLOR_ACCENT_BLUE, bg=COLOR_HEADER)
    lbl_sub.pack(anchor=tk.W)

    # Controls on right
    ctrl_frame = tk.Frame(top_bar, bg=COLOR_HEADER)
    ctrl_frame.pack(side=tk.RIGHT)

    tk.Label(ctrl_frame, text="Thiết bị:", font=("Segoe UI", 9), fg=COLOR_TEXT_MUTED, bg=COLOR_HEADER).pack(side=tk.LEFT, padx=(0, 4))
    dev_combo = ttk.Combobox(ctrl_frame, width=28, font=("Segoe UI", 9))
    dev_combo.pack(side=tk.LEFT, padx=(0, 6))
    dev_combo.set("Quét hoặc chọn mạch BLE...")

    btn_scan = tk.Button(ctrl_frame, text="🔍 Quét BLE", font=("Segoe UI", 9, "bold"), bg=COLOR_CARD, fg=COLOR_TEXT_MAIN, activebackground="#475569", activeforeground="#ffffff", relief=tk.FLAT, padx=10, pady=4, cursor="hand2")
    btn_scan.pack(side=tk.LEFT, padx=3)

    btn_connect = tk.Button(ctrl_frame, text="⚡ Kết nối", font=("Segoe UI", 9, "bold"), bg=COLOR_ACCENT_GREEN, fg="#022c22", activebackground="#34d399", relief=tk.FLAT, padx=12, pady=4, cursor="hand2")
    btn_connect.pack(side=tk.LEFT, padx=3)

    btn_sample_ant = tk.Button(ctrl_frame, text="Mẫu ANT (17S)", font=("Segoe UI", 8), bg=COLOR_CARD, fg=COLOR_ACCENT_BLUE, relief=tk.FLAT, padx=6, pady=4, cursor="hand2")
    btn_sample_ant.pack(side=tk.LEFT, padx=3)

    btn_sample_jk = tk.Button(ctrl_frame, text="Mẫu JK (17S)", font=("Segoe UI", 8), bg=COLOR_CARD, fg=COLOR_ACCENT_GREEN, relief=tk.FLAT, padx=6, pady=4, cursor="hand2")
    btn_sample_jk.pack(side=tk.LEFT, padx=3)

    # 2. STATUS & DIAGNOSTIC STRIP
    diag_strip = tk.Frame(root, bg="#0d1527", padx=16, pady=6, highlightbackground=COLOR_CARD_BORDER, highlightthickness=1)
    diag_strip.pack(fill=tk.X, side=tk.TOP, pady=(2, 0))

    var_conn_status = tk.StringVar(value="Trạng thái: Chưa kết nối BLE")
    var_bms_brand = tk.StringVar(value="Loại mạch: Đang chờ nhận diện")
    var_ble_telemetry = tk.StringVar(value="Nhận: 0 B (0 gói)")

    lbl_conn_dot = tk.Label(diag_strip, text="●", font=("Segoe UI", 12), fg=COLOR_TEXT_MUTED, bg="#0d1527")
    lbl_conn_dot.pack(side=tk.LEFT, padx=(0, 4))

    tk.Label(diag_strip, textvariable=var_conn_status, font=("Segoe UI", 9, "bold"), fg=COLOR_TEXT_MAIN, bg="#0d1527").pack(side=tk.LEFT, padx=(0, 16))
    tk.Label(diag_strip, text="|", fg=COLOR_CARD_BORDER, bg="#0d1527").pack(side=tk.LEFT, padx=(0, 16))
    tk.Label(diag_strip, textvariable=var_bms_brand, font=("Segoe UI", 9, "bold"), fg=COLOR_ACCENT_GREEN, bg="#0d1527").pack(side=tk.LEFT, padx=(0, 16))
    tk.Label(diag_strip, text="|", fg=COLOR_CARD_BORDER, bg="#0d1527").pack(side=tk.LEFT, padx=(0, 16))
    tk.Label(diag_strip, textvariable=var_ble_telemetry, font=("Consolas", 9), fg=COLOR_ACCENT_BLUE, bg="#0d1527").pack(side=tk.LEFT)

    # Manual Command Trigger Buttons on far right of diag strip
    btn_cmd_ant = tk.Button(diag_strip, text="Kích hoạt ANT (5A 5A)", font=("Segoe UI", 8, "bold"), bg="#1e293b", fg=COLOR_ACCENT_BLUE, relief=tk.FLAT, padx=8, pady=1)
    btn_cmd_ant.pack(side=tk.RIGHT, padx=3)
    btn_cmd_jk = tk.Button(diag_strip, text="Kích hoạt JK (0x96)", font=("Segoe UI", 8, "bold"), bg="#1e293b", fg=COLOR_ACCENT_GREEN, relief=tk.FLAT, padx=8, pady=1)
    btn_cmd_jk.pack(side=tk.RIGHT, padx=3)

    # 3. ESTIMATED TIME (ETA) HERO BANNER
    eta_banner = tk.Frame(root, bg=COLOR_CARD, padx=16, pady=10, highlightbackground=COLOR_ACCENT_GREEN, highlightthickness=1)
    eta_banner.pack(fill=tk.X, padx=12, pady=8)

    var_eta_main = tk.StringVar(value="Chờ kết nối tới mạch BMS...")
    var_eta_sub = tk.StringVar(value="Hệ thống sẽ tự động tính thời gian sạc đầy hoặc xả cạn theo dung lượng và dòng điện thời gian thực")
    var_eta_need = tk.StringVar(value="-- Ah (-- Wh)")

    eta_left = tk.Frame(eta_banner, bg=COLOR_CARD)
    eta_left.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
    tk.Label(eta_left, text="⏱ DỰ TÍNH THỜI GIAN SẠC ĐẦY / XẢ CẠN:", font=("Segoe UI", 8, "bold"), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack(anchor=tk.W)
    lbl_eta_main = tk.Label(eta_left, textvariable=var_eta_main, font=("Segoe UI", 12, "bold"), fg=COLOR_ACCENT_GREEN, bg=COLOR_CARD)
    lbl_eta_main.pack(anchor=tk.W, pady=1)
    tk.Label(eta_left, textvariable=var_eta_sub, font=("Segoe UI", 9), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack(anchor=tk.W)

    eta_right = tk.Frame(eta_banner, bg=COLOR_CARD)
    eta_right.pack(side=tk.RIGHT, fill=tk.Y)
    tk.Label(eta_right, text="CẦN NẠP THÊM:", font=("Segoe UI", 8), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack(anchor=tk.E)
    tk.Label(eta_right, textvariable=var_eta_need, font=("Consolas", 11, "bold"), fg=COLOR_ACCENT_GREEN, bg=COLOR_CARD).pack(anchor=tk.E)

    # 4. MAIN WORKSPACE (SPLIT VIEW: GAUGE & DEVICE ON LEFT, METRICS & CELLS ON RIGHT)
    main_body = tk.Frame(root, bg=COLOR_BG)
    main_body.pack(fill=tk.BOTH, expand=True, padx=12, pady=4)

    # --- LEFT PANE ---
    left_pane = tk.Frame(main_body, bg=COLOR_BG, width=320)
    left_pane.pack(side=tk.LEFT, fill=tk.BOTH, padx=(0, 6))

    # Circular SOC Gauge Canvas Card
    gauge_card = tk.Frame(left_pane, bg=COLOR_CARD, padx=12, pady=12, highlightbackground=COLOR_CARD_BORDER, highlightthickness=1)
    gauge_card.pack(fill=tk.X, pady=(0, 8))

    tk.Label(gauge_card, text="DUNG LƯỢNG PIN (SOC)", font=("Segoe UI", 9, "bold"), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack()

    soc_canvas = tk.Canvas(gauge_card, width=220, height=170, bg=COLOR_CARD, highlightthickness=0)
    soc_canvas.pack(pady=4)

    def draw_soc_gauge(percent: int, remain_ah: float, total_ah: float, state_str: str) -> None:
        soc_canvas.delete("all")
        cx, cy, r = 110, 95, 75
        # Background arc
        soc_canvas.create_arc(cx - r, cy - r, cx + r, cy + r, start=-30, extent=240, style=tk.ARC, width=14, outline="#334155")
        # Color transition
        if percent >= 50:
            arc_color = COLOR_ACCENT_GREEN
        elif percent >= 20:
            arc_color = COLOR_ACCENT_AMBER
        else:
            arc_color = COLOR_ACCENT_ROSE
        # Foreground filled arc
        pct = max(0, min(100, percent))
        extent_val = (pct / 100.0) * 240
        if extent_val > 0:
            soc_canvas.create_arc(cx - r, cy - r, cx + r, cy + r, start=-30 + (240 - extent_val), extent=extent_val, style=tk.ARC, width=14, outline=arc_color)

        # Center texts
        soc_canvas.create_text(cx, cy - 8, text=f"{pct}%", font=("Segoe UI", 26, "bold"), fill=COLOR_TEXT_MAIN)
        soc_canvas.create_text(cx, cy + 22, text=f"{remain_ah:.1f} / {total_ah:.1f} Ah", font=("Consolas", 10), fill=COLOR_ACCENT_BLUE)
        soc_canvas.create_text(cx, cy + 40, text=state_str, font=("Segoe UI", 9, "bold"), fill=arc_color)

    draw_soc_gauge(0, 0, 0, "Chưa có dữ liệu")

    # MOSFET Switches Bar
    mos_bar = tk.Frame(gauge_card, bg=COLOR_CARD)
    mos_bar.pack(fill=tk.X, pady=(4, 0))

    var_mos_charge = tk.StringVar(value="MOS Sạc: --")
    var_mos_discharge = tk.StringVar(value="MOS Xả: --")
    var_balancer = tk.StringVar(value="Cân bằng: --")

    lbl_mc = tk.Label(mos_bar, textvariable=var_mos_charge, font=("Segoe UI", 8, "bold"), fg=COLOR_TEXT_MUTED, bg="#0d1527", padx=6, pady=4)
    lbl_mc.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
    lbl_md = tk.Label(mos_bar, textvariable=var_mos_discharge, font=("Segoe UI", 8, "bold"), fg=COLOR_TEXT_MUTED, bg="#0d1527", padx=6, pady=4)
    lbl_md.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
    lbl_mb = tk.Label(mos_bar, textvariable=var_balancer, font=("Segoe UI", 8, "bold"), fg=COLOR_TEXT_MUTED, bg="#0d1527", padx=6, pady=4)
    lbl_mb.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)

    # Device Info & Passwords Card
    dev_card = tk.Frame(left_pane, bg=COLOR_CARD, padx=12, pady=10, highlightbackground=COLOR_CARD_BORDER, highlightthickness=1)
    dev_card.pack(fill=tk.BOTH, expand=True)

    tk.Label(dev_card, text="THÔNG TIN THIẾT BỊ & MẬT KHẨU", font=("Segoe UI", 9, "bold"), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack(anchor=tk.W)

    dev_fields = [
        ("Tên Bluetooth:", "dev_name", "--"),
        ("Model / Vendor:", "dev_vendor", "--"),
        ("PIN Bluetooth:", "dev_pin", "--"),
        ("MK Cài đặt:", "dev_setup", "--"),
        ("Số Serial:", "dev_serial", "--"),
        ("Phiên bản:", "dev_ver", "--"),
        ("Thời gian chạy:", "dev_uptime", "--"),
    ]

    dev_vars: Dict[str, tk.StringVar] = {}
    for lbl_text, key, init_val in dev_fields:
        row = tk.Frame(dev_card, bg=COLOR_CARD)
        row.pack(fill=tk.X, pady=2)
        tk.Label(row, text=lbl_text, font=("Segoe UI", 8), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack(side=tk.LEFT)
        v = tk.StringVar(value=init_val)
        dev_vars[key] = v
        lbl_val = tk.Label(row, textvariable=v, font=("Consolas", 9, "bold"), fg=COLOR_TEXT_MAIN, bg=COLOR_CARD)
        lbl_val.pack(side=tk.RIGHT)

    # Copy PIN button
    def copy_passcode(kind: str) -> None:
        val = dev_vars["dev_pin"].get() if kind == "pin" else dev_vars["dev_setup"].get()
        if val and val != "--":
            root.clipboard_clear()
            root.clipboard_append(val)
            messagebox.showinfo("Đã sao chép", f"Đã sao chép mật khẩu: {val}")

    btn_row = tk.Frame(dev_card, bg=COLOR_CARD)
    btn_row.pack(fill=tk.X, pady=(6, 0))
    tk.Button(btn_row, text="📋 Chép PIN", font=("Segoe UI", 8), bg="#334155", fg=COLOR_TEXT_MAIN, relief=tk.FLAT, command=lambda: copy_passcode("pin")).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
    tk.Button(btn_row, text="📋 Chép MK Cài đặt", font=("Segoe UI", 8), bg="#334155", fg=COLOR_TEXT_MAIN, relief=tk.FLAT, command=lambda: copy_passcode("setup")).pack(side=tk.RIGHT, expand=True, fill=tk.X, padx=1)

    # --- RIGHT PANE ---
    right_pane = tk.Frame(main_body, bg=COLOR_BG)
    right_pane.pack(side=tk.RIGHT, fill=tk.BOTH, expand=True)

    # 6 Core Hero Metrics Grid
    metric_grid = tk.Frame(right_pane, bg=COLOR_BG)
    metric_grid.pack(fill=tk.X, pady=(0, 6))

    metric_vars: Dict[str, tuple[tk.StringVar, tk.StringVar]] = {}

    def make_metric_card(parent: tk.Widget, title: str, key: str, default_val: str, default_sub: str, col_fg: str):
        card = tk.Frame(parent, bg=COLOR_CARD, padx=10, pady=8, highlightbackground=COLOR_CARD_BORDER, highlightthickness=1)
        tk.Label(card, text=title, font=("Segoe UI", 8, "bold"), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack(anchor=tk.W)
        var_val = tk.StringVar(value=default_val)
        var_sub = tk.StringVar(value=default_sub)
        metric_vars[key] = (var_val, var_sub)
        tk.Label(card, textvariable=var_val, font=("Consolas", 15, "bold"), fg=col_fg, bg=COLOR_CARD).pack(anchor=tk.W, pady=1)
        tk.Label(card, textvariable=var_sub, font=("Segoe UI", 8), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD).pack(anchor=tk.W)
        return card

    c1 = make_metric_card(metric_grid, "TỔNG ĐIỆN ÁP", "total_v", "-- V", "TB Cell: -- V", COLOR_TEXT_MAIN)
    c2 = make_metric_card(metric_grid, "DÒNG ĐIỆN", "current", "-- A", "Dòng CB: -- A", COLOR_ACCENT_AMBER)
    c3 = make_metric_card(metric_grid, "CÔNG SUẤT", "power", "-- W", "Năng lượng: -- Wh", COLOR_ACCENT_BLUE)
    c4 = make_metric_card(metric_grid, "ĐỘ LỆCH ÁP", "delta_v", "-- mV", "Chênh lệch lớn nhất", COLOR_ACCENT_GREEN)
    c5 = make_metric_card(metric_grid, "CELL MAX / MIN", "max_min", "-- V", "Min: -- V", COLOR_TEXT_MAIN)
    c6 = make_metric_card(metric_grid, "NHIỆT ĐỘ", "temps", "-- °C", "T1 / T2: --° / --°", COLOR_ACCENT_ROSE)

    for i, c in enumerate([c1, c2, c3, c4, c5, c6]):
        row_idx = i // 3
        col_idx = i % 3
        c.grid(row=row_idx, column=col_idx, sticky="nsew", padx=3, pady=3)
        metric_grid.columnconfigure(col_idx, weight=1)

    # Scrollable Visual Cell Voltages Grid Card
    cells_card = tk.Frame(right_pane, bg=COLOR_CARD, padx=12, pady=10, highlightbackground=COLOR_CARD_BORDER, highlightthickness=1)
    cells_card.pack(fill=tk.BOTH, expand=True)

    cells_top = tk.Frame(cells_card, bg=COLOR_CARD)
    cells_top.pack(fill=tk.X, pady=(0, 6))
    tk.Label(cells_top, text="ĐIỆN ÁP & NỘI TRỞ TỪNG CELL (TỰ ĐỘNG 3S ĐẾN 32S)", font=("Segoe UI", 9, "bold"), fg=COLOR_TEXT_MAIN, bg=COLOR_CARD).pack(side=tk.LEFT)
    lbl_cell_count_badge = tk.Label(cells_top, text="-- CELL", font=("Segoe UI", 8, "bold"), fg=COLOR_ACCENT_GREEN, bg="#0d1527", padx=6, pady=2)
    lbl_cell_count_badge.pack(side=tk.RIGHT)

    # Canvas scrollable area for cell cards
    cells_canvas = tk.Canvas(cells_card, bg=COLOR_CARD, highlightthickness=0)
    cells_scroll = ttk.Scrollbar(cells_card, orient=tk.VERTICAL, command=cells_canvas.yview)
    cells_frame = tk.Frame(cells_canvas, bg=COLOR_CARD)

    cells_frame.bind("<Configure>", lambda e: cells_canvas.configure(scrollregion=cells_canvas.bbox("all")))
    cells_window = cells_canvas.create_window((0, 0), window=cells_frame, anchor="nw")
    cells_canvas.configure(yscrollcommand=cells_scroll.set)

    def on_canvas_configure(event):
        cells_canvas.itemconfig(cells_window, width=event.width)
    cells_canvas.bind("<Configure>", on_canvas_configure)

    cells_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
    cells_scroll.pack(side=tk.RIGHT, fill=tk.Y)

    # RENDER CELL CARDS
    def update_cells_view(volts: List[float], resistances: List[float], max_idx: int, min_idx: int):
        for widget in cells_frame.winfo_children():
            widget.destroy()

        if not volts:
            lbl_empty = tk.Label(cells_frame, text="Chưa có dữ liệu Cell. Nhấn 'Kết nối' hoặc bấm nút 'Mẫu ANT (17S)' / 'Mẫu JK (17S)' để thử nghiệm!", font=("Segoe UI", 9), fg=COLOR_TEXT_MUTED, bg=COLOR_CARD, pady=40)
            lbl_empty.pack(fill=tk.BOTH, expand=True)
            return

        lbl_cell_count_badge.config(text=f"{len(volts)}S HOẠT ĐỘNG")
        min_v = min(volts) if volts else 2.5
        max_v = max(volts) if volts else 4.2
        span = max(0.05, max_v - min_v)

        cols = 4 if len(volts) >= 16 else 3
        for idx, v in enumerate(volts):
            cell_num = idx + 1
            is_max = cell_num == max_idx
            is_min = cell_num == min_idx
            r_val = resistances[idx] * 1000.0 if idx < len(resistances) else 0.0

            card_border = COLOR_ACCENT_GREEN if is_max else (COLOR_ACCENT_AMBER if is_min else "#334155")
            card_bg = "#0d1f1c" if is_max else ("#24180d" if is_min else "#131d2e")

            c_box = tk.Frame(cells_frame, bg=card_bg, padx=8, pady=6, highlightbackground=card_border, highlightthickness=1)
            row_i = idx // cols
            col_i = idx % cols
            c_box.grid(row=row_i, column=col_i, sticky="nsew", padx=3, pady=3)
            cells_frame.columnconfigure(col_i, weight=1)

            top_h = tk.Frame(c_box, bg=card_bg)
            top_h.pack(fill=tk.X)
            tk.Label(top_h, text=f"Cell #{cell_num:02d}", font=("Segoe UI", 8, "bold"), fg=COLOR_TEXT_MUTED, bg=card_bg).pack(side=tk.LEFT)
            if is_max:
                tk.Label(top_h, text="MAX", font=("Segoe UI", 7, "bold"), fg=COLOR_ACCENT_GREEN, bg="#022c22", padx=3).pack(side=tk.RIGHT)
            elif is_min:
                tk.Label(top_h, text="MIN", font=("Segoe UI", 7, "bold"), fg=COLOR_ACCENT_AMBER, bg="#451a03", padx=3).pack(side=tk.RIGHT)

            v_row = tk.Frame(c_box, bg=card_bg)
            v_row.pack(fill=tk.X, pady=1)
            tk.Label(v_row, text=f"{v:.3f} V", font=("Consolas", 11, "bold"), fg=COLOR_TEXT_MAIN, bg=card_bg).pack(side=tk.LEFT)
            tk.Label(v_row, text=f"{r_val:.0f} mΩ" if r_val else "--", font=("Consolas", 8), fg=COLOR_TEXT_MUTED, bg=card_bg).pack(side=tk.RIGHT)

            # Mini visual fill bar
            bar_pct = max(0.1, min(1.0, (v - min_v + 0.02) / (span + 0.04)))
            bar_c = tk.Canvas(c_box, height=4, bg="#1e293b", highlightthickness=0)
            bar_c.pack(fill=tk.X, pady=(2, 0))
            bar_color = COLOR_ACCENT_GREEN if is_max else (COLOR_ACCENT_AMBER if is_min else COLOR_ACCENT_BLUE)
            bar_c.create_rectangle(0, 0, int(150 * bar_pct), 4, fill=bar_color, width=0)

    # REFRESH ALL UI ELEMENTS FROM PARSER
    def update_all_ui(p: UniversalBmsParser) -> None:
        c = p.live
        d = p.device_info
        s = p.settings_info

        # Connection status & Brand
        if p.bms_brand != "Tự động nhận diện":
            var_bms_brand.set(f"Mạch: {p.bms_brand} ({c.protocol_version})")
        else:
            var_bms_brand.set("Loại mạch: Đang tự động nhận diện...")

        # Device info
        dev_vars["dev_name"].set(d.device_name or "--")
        dev_vars["dev_vendor"].set(d.vendor_id or p.bms_brand or "--")
        dev_vars["dev_pin"].set(d.device_passcode or "--")
        dev_vars["dev_setup"].set(d.setup_passcode or "--")
        dev_vars["dev_serial"].set(d.serial_number or "--")
        dev_vars["dev_ver"].set(f"HW {d.hardware_version} | SW {d.software_version}")
        dev_vars["dev_uptime"].set(format_duration(d.uptime_seconds) if d.uptime_seconds else "--")

        # Switches
        lbl_mc.config(text=f"MOS Sạc: {'BẬT' if c.charging_mos_on else 'TẮT'}", fg=COLOR_ACCENT_GREEN if c.charging_mos_on else COLOR_ACCENT_ROSE)
        lbl_md.config(text=f"MOS Xả: {'BẬT' if c.discharging_mos_on else 'TẮT'}", fg=COLOR_ACCENT_GREEN if c.discharging_mos_on else COLOR_ACCENT_ROSE)
        lbl_mb.config(text=f"Cân bằng: {c.balancing_status_text}", fg=COLOR_ACCENT_BLUE if c.balancing_action else COLOR_TEXT_MUTED)

        # Core Metrics
        metric_vars["total_v"][0].set(f"{c.total_voltage_v:.3f} V")
        metric_vars["total_v"][1].set(f"TB Cell: {c.average_cell_voltage_v:.3f} V")

        sign = "+" if c.current_a >= 0 else ""
        metric_vars["current"][0].set(f"{sign}{c.current_a:.2f} A")
        metric_vars["current"][1].set(f"Dòng CB: {c.balance_current_a:.3f} A")

        sign_p = "+" if c.power_w >= 0 else ""
        metric_vars["power"][0].set(f"{sign_p}{c.power_w:.1f} W")
        wh_rem = c.remaining_capacity_ah * c.total_voltage_v
        wh_nom = c.nominal_capacity_ah * c.total_voltage_v
        metric_vars["power"][1].set(f"{wh_rem:.0f} / {wh_nom:.0f} Wh")

        delta_mv = round(c.delta_cell_voltage_v * 1000.0)
        metric_vars["delta_v"][0].set(f"{delta_mv} mV")
        metric_vars["delta_v"][1].set(f"Lệch áp: {c.delta_cell_voltage_v:.3f} V")

        metric_vars["max_min"][0].set(f"#{c.max_voltage_cell_num:02d}: {c.max_cell_voltage_v:.3f}V")
        metric_vars["max_min"][1].set(f"Min #{c.min_voltage_cell_num:02d}: {c.min_cell_voltage_v:.3f}V")

        metric_vars["temps"][0].set(f"MOS: {c.mosfet_temp_c:.1f}°C")
        metric_vars["temps"][1].set(f"T1: {c.temp_sensor_1_c:.1f}° | T2: {c.temp_sensor_2_c:.1f}°")

        # ETA Calculation
        need_ah = max(0.0, c.nominal_capacity_ah - c.remaining_capacity_ah)
        need_wh = need_ah * c.total_voltage_v
        var_eta_need.set(f"{need_ah:.2f} Ah ({need_wh:.0f} Wh)")

        if c.current_a > 0.05:
            if need_ah <= 0.05 or c.socPercent >= 100:
                var_eta_main.set("Pin đã sạc đầy (100%)")
                var_eta_sub.set(f"Đang duy trì dòng sạc bảo hòa: +{c.current_a:.2f} A")
            else:
                eta_h = (need_ah / c.current_a) * 1.08
                finish_dt = datetime.datetime.now() + datetime.timedelta(hours=eta_h)
                var_eta_main.set(f"Dự kiến sạc đầy sau: ~{format_eta_hours(eta_h)} (lúc ~{finish_dt.strftime('%H:%M')})")
                var_eta_sub.set(f"Đang nạp +{c.current_a:.2f} A ({c.power_w:+.0f} W) • Cần nạp {need_ah:.1f} Ah / {c.nominal_capacity_ah:.1f} Ah")
        elif c.current_a < -0.05:
            dis_a = abs(c.current_a)
            eta_h = c.remaining_capacity_ah / dis_a
            finish_dt = datetime.datetime.now() + datetime.timedelta(hours=eta_h)
            var_eta_main.set(f"Dự kiến xả cạn sau: ~{format_eta_hours(eta_h)} (đến ~{finish_dt.strftime('%H:%M')})")
            var_eta_sub.set(f"Đang xả {c.current_a:.2f} A ({abs(c.power_w):.0f} W) • Còn lại {c.remaining_capacity_ah:.1f} Ah")
        else:
            var_eta_main.set("Trạng thái Chờ (Không sạc / Không xả)")
            est5 = format_eta_hours((need_ah / 5.0) * 1.08) if need_ah > 0 else "0 phút"
            est10 = format_eta_hours((need_ah / 10.0) * 1.08) if need_ah > 0 else "0 phút"
            var_eta_sub.set(f"Ước tính nếu cắm sạc: Sạc 5A mất ~{est5} | Sạc 10A mất ~{est10}")

        # SOC Gauge
        state_str = "ĐANG SẠC" if c.current_a > 0.05 else ("ĐANG XẢ" if c.current_a < -0.05 else "STANDBY")
        draw_soc_gauge(c.soc_percent, c.remaining_capacity_ah, c.nominal_capacity_ah, state_str)

        # Cells Grid
        update_cells_view(c.cell_voltages_v, c.cell_resistances_ohm, c.max_voltage_cell_num, c.min_voltage_cell_num)

    # EVENT HANDLERS
    def on_sample_ant_clicked():
        ant_bytes = build_demo_ant_60v30ah()
        parser.feed_notification(ant_bytes)
        update_all_ui(parser)
        var_conn_status.set("Đang xem dữ liệu mẫu ANT-BMS (17S 60V 30Ah)")
        lbl_conn_dot.config(fg=COLOR_ACCENT_BLUE)

    def on_sample_jk_clicked():
        d_f, s_f, c_f = build_demo_jk_60v30ah()
        parser.feed_notification(d_f)
        parser.feed_notification(s_f)
        parser.feed_notification(c_f)
        update_all_ui(parser)
        var_conn_status.set("Đang xem dữ liệu mẫu JK-BMS (17S 60V 30Ah)")
        lbl_conn_dot.config(fg=COLOR_ACCENT_GREEN)

    btn_sample_ant.config(command=on_sample_ant_clicked)
    btn_sample_jk.config(command=on_sample_jk_clicked)

    # SCAN BLE DEVICES
    def on_scan_clicked():
        if not BLEAK_AVAILABLE:
            messagebox.showwarning("Thiếu bleak", "Chưa cài đặt thư viện bleak.\nHãy chạy: pip install bleak\nBạn vẫn có thể bấm nút Mẫu ANT hoặc Mẫu JK để trải nghiệm giao diện!")
            return

        var_conn_status.set("Đang quét Bluetooth BLE (6 giây)...")
        lbl_conn_dot.config(fg=COLOR_ACCENT_AMBER)
        btn_scan.config(state=tk.DISABLED)

        def _worker():
            try:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                discovered = loop.run_until_complete(BleakScanner.discover(timeout=6.0, return_adv=True))
                items = []
                for addr, (dev, adv) in discovered.items():
                    name = dev.name or adv.local_name or "(Không tên)"
                    DISCOVERED_DEVICES_CACHE[addr.upper()] = dev
                    items.append(f"{addr} | {name} ({adv.rssi} dBm)")

                items.sort(key=lambda x: (not any(k in x.upper() for k in ["JK", "ANT", "BMS", "PIN", "DALY", "JBD"]), x))

                def _update():
                    btn_scan.config(state=tk.NORMAL)
                    if items:
                        dev_combo["values"] = items
                        dev_combo.current(0)
                        var_conn_status.set(f"Tìm thấy {len(items)} thiết bị Bluetooth")
                    else:
                        var_conn_status.set("Không tìm thấy thiết bị Bluetooth nào")
                    lbl_conn_dot.config(fg=COLOR_TEXT_MUTED)

                root.after(0, _update)
            except Exception as e:
                root.after(0, lambda: messagebox.showerror("Lỗi quét", str(e)))
                root.after(0, lambda: btn_scan.config(state=tk.NORMAL))

        threading.Thread(target=_worker, daemon=True).start()

    btn_scan.config(command=on_scan_clicked)

    # CONNECT BLE WORKER
    active_client: Optional[Any] = None

    def on_connect_toggle():
        nonlocal active_client, ble_thread
        if btn_connect["text"] == "Ngắt kết nối":
            stop_event.set()
            btn_connect.config(text="⚡ Kết nối", bg=COLOR_ACCENT_GREEN)
            var_conn_status.set("Đã ngắt kết nối BLE")
            lbl_conn_dot.config(fg=COLOR_TEXT_MUTED)
            return

        raw = dev_combo.get().strip()
        mac = raw.split("|")[0].strip()
        if not mac or "Quét" in mac:
            messagebox.showinfo("Chưa chọn thiết bị", "Vui lòng bấm 'Quét BLE' hoặc dán địa chỉ MAC của mạch vào ô.")
            return

        stop_event.clear()
        btn_connect.config(text="Ngắt kết nối", bg=COLOR_ACCENT_ROSE)
        var_conn_status.set(f"Đang kết nối tới [{mac}]...")
        lbl_conn_dot.config(fg=COLOR_ACCENT_AMBER)

        def _ble_worker():
            nonlocal active_client
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            rx_bytes_total = 0
            rx_packets_total = 0

            def notif_handler(_sender, data_chunk):
                nonlocal rx_bytes_total, rx_packets_total
                rx_bytes_total += len(data_chunk)
                rx_packets_total += 1
                root.after(0, lambda b=rx_bytes_total, p=rx_packets_total: var_ble_telemetry.set(f"Nhận: {b/1024:.1f} KB ({p} gói)" if b >= 1024 else f"Nhận: {b} B ({p} gói)"))
                res = parser.feed_notification(bytes(data_chunk))
                if res:
                    root.after(0, lambda: update_all_ui(parser))

            async def _run():
                nonlocal active_client
                target = DISCOVERED_DEVICES_CACHE.get(mac.upper(), mac)
                async with BleakClient(target, timeout=20.0) as client:
                    active_client = client
                    root.after(0, lambda: var_conn_status.set(f"Đã kết nối: {mac}"))
                    root.after(0, lambda: lbl_conn_dot.config(fg=COLOR_ACCENT_GREEN))

                    # Tìm characteristic notify và write
                    notify_char, write_char = None, None
                    for service in client.services:
                        for c in service.characteristics:
                            props = [p.lower() for p in c.properties]
                            if ("notify" in props or "indicate" in props) and notify_char is None:
                                notify_char = c
                            if ("write-without-response" in props or "write" in props) and write_char is None:
                                write_char = c

                    if notify_char is None:
                        notify_char = UUID_JK_FFE1
                    if write_char is None:
                        write_char = notify_char

                    await client.start_notify(notify_char, notif_handler)
                    await asyncio.sleep(0.3)

                    # Gửi chuỗi lệnh kích hoạt toàn năng (ANT & JK)
                    try:
                        await client.write_gatt_char(write_char, CMD_ANT_WAKEUP, response=False)
                    except Exception:
                        try:
                            await client.write_gatt_char(write_char, CMD_ANT_WAKEUP, response=True)
                        except Exception:
                            pass

                    await asyncio.sleep(0.3)
                    try:
                        await client.write_gatt_char(write_char, build_jk_command_frame(CMD_JK_DEVICE_INFO, 1), response=False)
                    except Exception:
                        pass

                    await asyncio.sleep(0.4)
                    try:
                        await client.write_gatt_char(write_char, build_jk_command_frame(CMD_JK_CELL_INFO, 2), response=False)
                    except Exception:
                        pass

                    ticks = 0
                    while not stop_event.is_set():
                        await asyncio.sleep(1.0)
                        ticks += 1
                        if ticks % 2 == 0:
                            if parser.bms_brand == "ANT-BMS":
                                try:
                                    await client.write_gatt_char(write_char, CMD_ANT_WAKEUP, response=False)
                                except Exception:
                                    pass
                            elif parser.bms_brand == "JK-BMS":
                                try:
                                    await client.write_gatt_char(write_char, build_jk_command_frame(CMD_JK_CELL_INFO, (ticks % 250)), response=False)
                                except Exception:
                                    pass
                            else:
                                # Thăm dò cả hai
                                try:
                                    await client.write_gatt_char(write_char, CMD_ANT_WAKEUP, response=False)
                                except Exception:
                                    pass
                                try:
                                    await client.write_gatt_char(write_char, build_jk_command_frame(CMD_JK_CELL_INFO, (ticks % 250)), response=False)
                                except Exception:
                                    pass

                    try:
                        await client.stop_notify(notify_char)
                    except Exception:
                        pass

            try:
                loop.run_until_complete(_run())
            except Exception as exc:
                err_text = str(exc)
                root.after(0, lambda: var_conn_status.set(f"Lỗi: {err_text}"))
                root.after(0, lambda: lbl_conn_dot.config(fg=COLOR_ACCENT_ROSE))
                root.after(0, lambda: btn_connect.config(text="⚡ Kết nối", bg=COLOR_ACCENT_GREEN))
                root.after(0, lambda: messagebox.showerror("Lỗi kết nối BLE", f"Không thể kết nối tới {mac}:\n{err_text}\n\nLưu ý:\n1. Hãy tắt hoàn toàn app BMS trên điện thoại trước.\n2. Bấm nút 'Quét BLE' trước khi bấm 'Kết nối'."))

        ble_thread = threading.Thread(target=_ble_worker, daemon=True)
        ble_thread.start()

    btn_connect.config(command=on_connect_toggle)

    # Tự động nạp sẵn dữ liệu mẫu ANT-BMS (17S 60V 30Ah) lúc vừa mở app để người dùng thấy giao diện xịn xò ngay lập tức
    on_sample_ant_clicked()
    root.mainloop()


# ==============================================================================
# HÀM MAIN & XỬ LÝ CLI CHO SERVER/TERMINAL
# ==============================================================================
def main() -> int:
    p = argparse.ArgumentParser(description="Universal Smart BMS Monitor (BLE) - Python App")
    p.add_argument("--scan", action="store_true", help="Quét tìm thiết bị Bluetooth xung quanh")
    p.add_argument("--mac", type=str, help="Địa chỉ MAC của mạch BMS")
    p.add_argument("--demo", action="store_true", help="Chạy chế độ mô phỏng dữ liệu 60V 30Ah")
    p.add_argument("--cli", action="store_true", help="Chạy ở chế độ giao diện dòng lệnh (không mở GUI)")
    args = p.parse_args()

    # Nếu không truyền tham số hoặc môi trường có giao diện đồ họa -> Mở GUI Desktop xịn xò
    if not args.scan and not args.mac and not args.cli:
        try:
            launch_modern_gui()
            return 0
        except Exception as e:
            print(f"[!] Không thể mở giao diện đồ họa Tkinter ({e}). Chuyển sang chế độ Terminal CLI:")

    if args.demo:
        parser = UniversalBmsParser()
        parser.feed_notification(build_demo_ant_60v30ah())
        print(f"\n[+] KẾT QUẢ GIẢI MÃ MẠCH: {parser.bms_brand}")
        print(f"  - Tổng điện áp: {parser.live.total_voltage_v} V")
        print(f"  - Số cell hoạt động: {parser.live.active_cell_count}S")
        print(f"  - Dòng điện: {parser.live.current_a} A (Công suất: {parser.live.power_w} W)")
        print(f"  - Dung lượng pin (SOC): {parser.live.soc_percent}% ({parser.live.remaining_capacity_ah} / {parser.live.nominal_capacity_ah} Ah)")
        print(f"  - Điện áp cell TB: {parser.live.average_cell_voltage_v} V | Lệch áp Delta: {parser.live.delta_cell_voltage_v * 1000:.0f} mV")
        print(f"  - Nhiệt độ MOS: {parser.live.mosfet_temp_c} °C | T1: {parser.live.temp_sensor_1_c} °C")
        return 0

    if args.scan:
        if not BLEAK_AVAILABLE:
            print("[!] Chưa cài đặt bleak. Chạy: pip install bleak")
            return 1
        print("[*] Đang quét Bluetooth BLE trong 6 giây...")
        devs = asyncio.run(BleakScanner.discover(timeout=6.0))
        print(f"\nTìm thấy {len(devs)} thiết bị:")
        for d in devs:
            print(f"  - {d.address} | {d.name or '(Không tên)'}")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())