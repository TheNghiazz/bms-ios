# Giao thức BLE BMS — Đặc tả (theo bộ giải mã Python gốc)

Tài liệu này là "hợp đồng" dùng khi port sang Swift và khi test với mạch thật.
Mọi offset dưới đây đối chiếu trực tiếp với `UniversalBmsParser` (dòng 212–540
của `tools/reference/universal_bms_ble_reader.py`).

> Định danh phiên bản golden: `Sources/BMSCore/Resources/golden_vectors.json`
> (sinh lại bằng `python tools/gen_golden_vectors.py`).

## 1. Nhận diện khung truyền

Bộ dò khung trượt (sliding window) trên luồng byte BLE, thứ tự ưu tiên:

| # | Header | Độ dài | Kiểm tra (bắt buộc) | Hãng ghi nhận |
|---|--------|--------|----------|---------------|
| 1 | `55 AA EB 90` | 300 | `sum(frame[0..<299]) & 0xFF == frame[299]` (CRC8) | JK-BMS |
| 2 | `AA 55 AA FF` | 140 | `sum(frame[4..<138]) & 0xFFFF == be16(frame, 138)` | ANT-BMS |
| 3 | `DD` | `data[3] + 7` | `cmd ∈ {0x03,0x04,0x05}`, `status ≤ 1`, `1 ≤ len ≤ 64`, trailer `0x77`, kiểm tra hợp lý dữ liệu | JBD BMS |
| 4 | `A5 01` / `A5 40` | 13 | `sum(frame[0..<12]) & 0xFF == frame[12]`, `cmd == 0x90`, điện áp/SOC hợp lý | Daly BMS |

Khung có header nhưng sai checksum/cấu trúc bị **loại** và đếm vào
`rejectedFrames` (không giải mã). Không khớp cả 4 → trượt tìm byte
`55/AA/DD/A5` tiếp theo; buffer > 2048 byte thì xóa để đồng bộ lại.

**Khóa hãng:** khung hợp lệ đầu tiên khóa `bmsBrand`. Từ đó chỉ khung cùng hãng
được nhận; nhiễu hoặc khung hãng khác không thể ghi đè dữ liệu đang đọc.

**Provenance:** decoder vẫn giữ giá trị mặc định cũ (ví dụ `"1234"` cho PIN khi
khung rỗng) để khớp golden vectors, nhưng ghi lại trường nào thực sự có trong
khung (`BMSDeviceInfoProvenance`). UI chỉ hiển thị trường có provenance; ở chế
độ demo thì hiển thị đầy đủ.


## 2. JK-BMS

### 2.1 Frame 0x03 — Device info

| Offset | Độ dài | Trường | Scale |
|---|---|---|---|
| 6 | 16 | `vendor_id` | chuỗi ASCI\0 |
| 22 | 8 | `hardware_version` | chuỗi |
| 30 | 8 | `software_version` | chuỗi |
| 38 | 4 | `uptime_seconds` | LE u32 |
| 42 | 4 | `power_on_count` | LE u32 |
| 46 | 16 | `device_name` | chuỗi |
| 62 | 16 | `device_passcode` (PIN Bluetooth) | chuỗi |
| 78 | 8 | `manufacturing_date` | `yymmdd` → `20yy-mm-dd` |
| 86 | 11 | `serial_number` | chuỗi |
| 97 | 5 | `passcode` (bản gốc đọc "0000" khi thiếu) | chuỗi |
| 102 | 16 | `user_data` | chuỗi |
| 118 | 16 | `setup_passcode` (MK cài đặt) | chuỗi |

**Quy tắc nhánh 24S vs 32S:** `software_version` chứa `"11."` hoặc `"12."`
→ `JK02_32S`, ngược lại `JK02_24S`.

**Cảnh báo hành vi gốc (đã khóa trong golden case `jk_32s_cells_first`):** nếu
frame 0x02 (cell) đến TRƯỚC 0x03 (device info) thì parser giữ protocolVersion
`AUTO` → decode 0x02 theo nhánh 24S, không re-decode khi nhận 0x03.
Ứng dụng thật đảo lệnh: gửi 0x97 (device info) trước rồi mới 0x96 (cell info).

### 2.2 Frame 0x01 — Settings

Tất cả LE u32, scale `*0.001`:

| Offset | Trường |
|---|---|
| 6 | smart sleep voltage |
| 10 / 14 | UVP cell / UVP recovery |
| 18 / 22 | OVP cell / OVP recovery |
| 26 | balanced trigger voltage |
| 46 | power off voltage |
| 50 / 62 | max charge / max discharge current (A) |
| 78 | max balance current (A) |
| 114 | `cell_count_configured` (u8) |
| 118 / 122 / 126 | switch sạc / xả / cân bằng (u8) |
| 130 | nominal capacity (Ah) |
| 138 | start balance voltage |

### 2.3 Frame 0x02 — Cell info (live)

Có 2 nhánh theo `is32 = (protocolVersion == "JK02_32S")`:

- `offset1 = is32 ? 16 : 0` (dịch khối nội trở)
- `offset2 = is32 ? 32 : 0` (dịch các trường phía sau)
- `num_cells = is32 ? 32 : 24`

| Offset (± offset2) | Trường | Scale |
|---|---|---|
| 6 + i*2 (i < num_cells) | cell voltage i (LE u16) | mV→V |
| 64 + offset1 + i*2 | cell resistance i (LE u16) | Ω (mΩ→…) |
| 112 + offset2 (chỉ 32S) | MOS temp i16 | 0.1 °C |
| 118 + offset2 | total voltage LE u32 | mV→V |
| 126 + offset2 | current <I> i32 | A |
| 130 / 132 + offset2 | temp sensor 1 / 2 i16 | 0.1 °C |
| 134 + offset2 | (32S) errors u32 — hoặc (24S) MOS temp i16 | 0.1 °C |
| 136 + offset2 (chỉ 24S) | errors u16 | bitmask |
| 138 + offset2 | balance current i16 | A |
| 140 + offset2 | balancing action u8 (1=Nạp, 2=Xả) |
| 141 + offset2 | SOC u8 (0–100) |
| 142 / 146 + offset2 | remaining / nominal capacity LE u32 (Ah) |
| 150 + offset2 | cycle count LE u32 |
| 154 + offset2 | total cycle capacity LE u32 (Ah) |
| 158 + offset2 | SOH u8 |
| 162 + offset2 | runtime seconds LE u32 |
| 166 / 167 / 168 + offset2 | MOS sạc ON / MOS xả ON / precharge (u8) |

Cell chỉ được tính khi `V > 0.05`; `min/maxVoltageCellNum` = vị trí (1-based).

### 2.4 Lệnh gửi xuống (20 byte)

`AA 55 90 EB | cmd | 00 ... (byte 5–15 = 0) | counter (byte 16) | 00 | CRC=(sum[0..<19])&0xFF (byte 19)`

- `0x96` — yêu cầu cell info (lệnh thông dụng, heartbeat mỗi 2 s)
- `0x97` — yêu cầu device info

### 2.5 UUID BLE & cách chọn kênh

`FFE0` service · `FFE1` notify/write (kênh dữ liệu + lệnh) · `FFE2` log debug.

App **không** chọn "characteristic notify đầu tiên" như bản Python gốc. Bộ chọn
`BLEEndpointSelector` (`Sources/BMSCore/Acquisition.swift`) chấm điểm:

1. tên quảng cáo gợi ý hãng (JK/JBD/Daly/ANT);
2. UUID đã biết của hãng (`FFE1` cho JK, `FF01`/`FF02` cho JBD, `FFF1`/`FFF2` cho Daly);
3. characteristic cùng service với kênh ghi;
4. loại `FFE2` (log) và các characteristic GATT chuẩn (`180F/2A19`, `1800/2A00`…).

Nhờ vậy JK luôn nhận dữ liệu trên `FFE1`, không rơi vào `FFE2`/Battery Level.
Màn hình **Quét & kết nối** hiển thị lý do chọn kênh trong mục chẩn đoán.


## 3. ANT-BMS (Mayi / JNFN 140B)

Khung 140 byte, tất cả big-endian, checksum 16-bit **bắt buộc**:

| Offset | Trường | Scale |
|---|---|---|
| 4 | total voltage (u16 BE) | 0.1 V |
| 6 + i*2 (i<32) | cell voltage (u16 BE) | mV→V; chỉ nhận `0.05 < V < 5.0` |
| 70 | current i32 BE | 0.1 A |
| 74 | SOC u8 (0–100, clamp) |
| 75 / 79 | nominal / remaining capacity u32 BE | tự dò scale (÷1e6 nếu >500k, ÷1e3 nếu >1k, ngược lại passthrough; fallback 30.0 / 25.0 Ah) |
| 83 / 87 | cycle count / runtime seconds u32 BE | nguyên |
| 91 / 93 / 99 | T1 / T2 / MOS temp i16 BE | không scale |
| 101 / 102 / 103 | MOS sạc / MOS xả / balancing action u8 | 0/1 |
| 138 | checksum u16 BE | `sum(bytes 4..<138) & 0xFFFF` |

Khung sai checksum bị loại trước khi giải mã. Golden case `ant_17s_demo` có
checksum đúng nên vẫn khớp; test `testANT_badChecksumIsRejectedThenGoodFrameAccepted`
xác nhận hành vi này.

Lệnh đánh thức: `5A 5A 00 00 00 00`, gửi mỗi 2 s khi đã nhận diện ANT.


## 4. JBD / Xiaoxiang / Overkill

Khung: `DD <cmd> <status> <len> <data...> <checksum 2B> 77`.

Chỉ khung có `cmd ∈ {0x03, 0x04, 0x05}` và `status ≤ 1` mới được xét; `len`
phải trong `1...64`, trailer phải là `0x77`. Ngoài ra:

- **0x03** (basic): total (u16 BE, 0.01 V) @4, current (i16 BE, 0.01 A) @6,
  remaining (0.01 Ah) @8, nominal @10, cycles @12, SOC u8 @23, MOS bitfield @24
  (bit0 sạc, bit1 xả). Bắt buộc `len ≥ 21`, `0 < total ≤ 120 V`, `SOC ≤ 100`.
- **0x04** (cells): `len = 2 * n_cell` (phải chẵn), mỗi cell u16 BE @4+i*2,
  scale mV→V, lọc `> 0.05`. KHÔNG set min/max cell position (khớp bản gốc).
- **0x05** (device name): chuỗi ASCII trong `data[4..<4+len]`; khung phải có
  tên không rỗng và toàn ký tự ASCII. Tên được ghi vào `deviceName` kèm
  provenance.

Hai byte checksum trước trailer không được kiểm vì firmware JBD dùng biến thể
CRC khác nhau; cấu trúc + trailer + cmd/len + kiểm tra hợp lý là đủ để loại nhiễu.


## 5. Daly Smart BMS

Khung 13 byte: `A5 <01|40> <cmd> ... <ck>` với `ck = sum(bytes 0..<12) & 0xFF`.

Chỉ đọc cmd `0x90`: total V (u16 BE, 0.1) @4–5, current = `((d8<<8|d9)-30000)*0.1`
(david offset 30000 tương đương 0 A), SOC = `((d10<<8|d11))*0.1`.
Điện áp từng cell Daly CHƯA được giải mã (known limitation — Phase 8 mở rộng).

## 6. Nhịp lệnh & kết nối (đã siết so với GUI gốc)

1. Quét 8 s → chọn thiết bị (khóa là `CBPeripheral.identifier`, không phải MAC).
2. Kết nối (timeout 12 s) → khám phá toàn bộ service/characteristic.
3. `BLEEndpointSelector` chọn kênh dữ liệu/ghi/poll; nếu kênh chính lỗi thì thử
   lần lượt các ứng viên notify rồi fallback sang `read` định kỳ.
4. **Đăng ký notify/indicate xong mới gửi lệnh** (chờ xác nhận CCCD tối đa 5 s).
   Trước đây lệnh được gửi ngay sau khi gọi `setNotifyValue`, nên trên mạch thật
   lệnh đầu tiên có thể rơi mất.
5. Kích hoạt theo hãng đã biết; nếu chưa rõ hãng thì thăm dò **tuần tự**
   (ANT → JK 0x97 → JK 0x96 → JBD 0x03 → JBD 0x05 → JBD 0x04 → Daly 0x90)
   trong 7,2 s, không dội 4 họ lệnh cùng lúc.
6. Heartbeat mỗi 1 s, gửi lệnh mỗi 2 s:
   - **JK**: `0x96` (live); mỗi 8 s gửi `0x97` (device info).
   - **JBD**: `0x05` khi chưa có tên; định kỳ `0x03` / `0x04`.
   - **Daly**: `0x90`. **ANT**: `5A 5A 00 00 00 00`.
7. Watchdog 1 s phân biệt rõ ba trạng thái: **không nhận byte nào** / **có byte
   nhưng không khung hợp lệ** / **có khung nhưng mất nhịp**. UI không báo
   "đang nhận dữ liệu" nếu chưa có khung hợp lệ.
8. Ghi lệnh: ưu tiên `writeWithoutResponse` nếu mạch khai báo; giữ lệnh mới nhất
   khi hàng đợi CoreBluetooth đầy và gửi lại ở `peripheralIsReady`.

Chỉ dữ liệu của đúng characteristic đã chọn được đẩy vào parser — log debug
`FFE2`, Battery Level `2A19` hay Device Name `2A00` không thể làm hỏng buffer.


## 7. Bug đã biết của chính file gốc (được khắc phục trong Swift)

| # | Vị trí | Bug | Cách xử lý trong port |
|---|---|---|---|
| 1 | `decode_all_ui` (dòng 998) | `c.socPercent` → `AttributeError` khi sạc đầy | Dùng `socPercent`; đã test `testEta_chargingFullFixesOriginalSocTypo` |
| 2 | `feed_notification` | `return` sau frame ĐẦU → frame kế bị trễ 1 lượt notification | Swift `feed()` xử lý hết buffer, trả `[BmsFrameEvent]` |
| 3 | `decode_jbd_frame (0x04)` | Quên set `min/maxVoltageCellNum` | Đã biết và giữ nguyên (khớp golden); xem xét nâng cấp Phase 8 |
| 4 | ANT | Không kiểm checksum khung | **Đã sửa**: bắt buộc checksum 16-bit @138 |
| 5 | JK 0x02 trước 0x03 | Decode theo nhánh 24S, không re-decode | Khóa bằng golden case `jk_32s_cells_first` |
| 6 | `build_demo_jk_60v30ah` | Gán chuỗi ngắn vào slice `bytearray` làm mảng co → `IndexError` khi chạy demo | Dựng khung demo bằng `set_str` đệm đúng độ dài trong `tools/gen_golden_vectors.py` |
| 7 | Daly | Cell voltage chưa giải mã | Known limitation |
| 8 | Chọn characteristic | Lấy notify/write ĐẦU TIÊN → trúng `FFE2`/`2A19`/`2A00`, "kết nối được nhưng không có dữ liệu" | `BLEEndpointSelector` chọn tất định theo hãng + service |
| 9 | Gửi lệnh | Gửi ngay trước khi CCCD bật xong | Chờ xác nhận notify (tối đa 5 s) rồi mới gửi |
| 10 | Parser | Mọi notify đều đổ vào buffer | Chỉ nhận characteristic đã chọn |
| 11 | UI | Giá trị mặc định của decoder hiện như dữ liệu thật | `BMSDeviceInfoProvenance` + trạng thái chờ dữ liệu thật |


## 8. Golden vectors hiện có (9 case)

| Case | Ý nghĩa |
|---|---|
| `ant_17s_demo` | ANT 17S 60V/30Ah (demo gốc) |
| `jk_24s_demo` | JK 24S 17 cell (demo gốc, dựng lại bằng set_str) |
| `jk_32s_synthetic` | JK 32S tổng hợp (0x03 trước 0x02) |
| `jk_32s_cells_first` | Khoá hành vi gốc khi 0x02 đến trước 0x03 |
| `jbd_basic_and_cells` | JBD 0x03 + 0x04 |
| `jbd_glued` | Hai frame JBD trong một lần feed |
| `daly_0x90` | Daly 0x90 (checksum đúng) |
| `jk_bad_crc_rejected` | CRC sai → không decode, brand mặc định |
| `junk_prefix_then_ant` | Byte rác phía trước → resync vẫn decode ANT |

Chế độ xác thực: mỗi case chạy **2 chế độ** — "separate" (mỗi frame một lần
`feed`) và "chunked" (glue + chia `1/3/7/13/20/64/182` byte) và kết quả
phải giống hệt nhau.
