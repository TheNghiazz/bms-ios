# BMS Monitor — iOS (SwiftUI + CoreBluetooth)

Port từ `universal_bms_ble_reader.py` (Tkinter + bleak, Windows) sang app iOS
đọc BMS qua Bluetooth BLE: **JK-BMS · ANT-BMS · JBD/Xiaoxiang · Daly**.
Logic giải mã được port ra **Swift Package thuần (`BMSCore`)** và đối chiếu
số liệu bằng **golden vectors** sinh từ chính code Python gốc.

App tập trung vào **lấy dữ liệu từ mạch**: hãng/mạch BMS, thông tin thiết bị
(model, serial, phiên bản, ngày sản xuất, thời gian chạy) và **mật khẩu**
(PIN BLE, mật khẩu cài đặt). Không hiển thị dung lượng pin, điện áp, dòng
điện hay % pin.

## Cấu trúc

```
bms-ios/
├─ Package.swift                  BMSCore (thuần Swift, test được Everywhere)
├─ Sources/BMSCore/               parser + 4 decoder + golden check
│  ├─ Acquisition.swift           chọn kênh BLE tất định (FFE1/FF01/FFF1…)
│  ├─ Discovery.swift             lọc thiết bị quét (chỉ mạch BMS)
│  └─ Resources/golden_vectors.json
├─ Sources/BMSCoreCheck/main.swift  chạy check kiểu executable (swift run)
├─ Tests/BMSCoreTests/            XCTest
├─ App/                           SwiftUI app (iOS 17+)
│  ├─ BMSMonitorApp.swift         @main + RootView (chuyển 2 trạng thái)
│  ├─ BMSStore.swift              trạng thái chung (parser + session)
│  ├─ BLE/BLESession.swift        CoreBluetooth: quét/kết nối/heartbeat
│  ├─ Components/Motion.swift     animation dùng chung (reveal/burstOut…)
│  ├─ Features/Connect/           màn hình chưa kết nối (nút BLE trung tâm)
│  ├─ Features/Device/            UI dữ liệu: mạch + thiết bị + mật khẩu
│  ├─ Features/Scan/ScanSheet.swift  quét/kết nối BLE + chẩn đoán
│  └─ Assets.xcassets/            icon app (AppIcon 1024, sinh bởi tools/gen_app_icon.py)
├─ tools/gen_golden_vectors.py    sinh golden vectors từ code Python gốc
├─ tools/gen_app_icon.py          sinh icon app 1024x1024 (thuần stdlib)
├─ tools/reference/               BẢN COPY file Python gốc làm oracle
├─ docs/protocol.md               đặc tả offset từng hãng + bug đã biết
├─ project.yml                    XcodeGen (sinh .xcodeproj)
└─ .github/workflows/ios.yml      CI build IPA không ký
```

## Workflow khi CHỈ CÓ Windows (không có Mac)

1. **Thay đổi code** → commit →push GitHub.
2. **CI (GitHub Actions, runner macOS miễn phí):**
   - `swift test` chạy golden vectors + unit test.
   - Build xcodebuild các Release-iphoneos **không ký** → artifact `BMSMonitor.ipa`.
3. **Cài lên iPhone (Sideloadly + Apple ID miễn phí):**
   - Tải artifact về máy Windows.
   - Cắm iPhone, mở Sideloadly → chọn .ipa → nhập Apple ID → Start.
   - iPhone: bật **Developer Mode** (Settings → Privacy & Security) nếu lần đầu;
     sau đó *Settings → General → VPN & Device Management* → tin cậy chứng chỉ.
4. **App hết hạn sau 7 ngày** → lặp lại bước 2–3 để cài đè (cùng bundle ID,
   dữ liệu thường vẫn giữ).

> Giới hạn Apple ID free: tối đa 3 app, 10 App ID/tuần, **không push
> notification**. Muốn ổn định lâu dài → nâng TestFlight (99 USD/năm).

## Chạy test / check

- **Có Swift (macOS/Linux/Windows toolchain):**
  ```
  swift test           # XCTest
  swift run bmscore-check   # không cần XCTest
  ```
  > Trên Windows + Swift 6.4, `swift test` có thể in "Test run with 0 tests"
  > rồi trả mã 1 dù toàn bộ XCTest đã pass. Dùng
  > `swift test --disable-swift-testing` để nhận mã thoát 0.
### Build BMSCore trên Windows (Swift 6.4+)

Swift 6.4 chuyển stdlib sang **Swift SDK tách rời** — nếu chỉ cài toolchain,
`swift build` sẽ báo `unable to load standard library for target`.
Cần trỏ `SDKROOT` vào Windows SDK đi kèm:

```powershell
$swift = "$env:LOCALAPPDATA\Programs\Swift"
$env:Path = "$swift\Toolchains\6.4.1+Asserts\usr\bin;$swift\Runtimes\6.4.1\usr\bin;" + $env:Path
$env:SDKROOT = "$swift\Platforms\6.4.1\Windows.platform\Developer\SDKs\Windows.sdk"

swift build
swift test
swift run bmscore-check
```

Ngoài ra cần **Visual Studio Build Tools 2022** (workload *Desktop development
with C++*) để có `link.exe`, `lib.exe` và Windows SDK. Nếu driver báo
`could not find CLI tool 'link'`, chạy lệnh từ *x64 Native Tools Command Prompt*
hoặc copy `link.exe`/`lib.exe` vào `…\Swift\Toolchains\<ver>\usr\bin`.

- **Sinh lại golden vectors** (sau khi sửa parser Python gốc):
  ```
  python tools/gen_golden_vectors.py
  ```

- **Sinh lại icon app** (sửa màu/hình trong script rồi chạy):
  ```
  python tools/gen_app_icon.py
  ```
  Script chỉ dùng stdlib nên chạy được cả trên Windows, không cần Pillow.
  Bundle ID: `vn.ngia.bmsreader` (khai báo trong `project.yml`).

## Cách app lấy dữ liệu từ mạch (bản siết)

Bản đầu tiên chọn "characteristic notify đầu tiên" và gửi lệnh ngay sau khi gọi
`setNotifyValue`. Trên JK-BMS thật, cách đó rất dễ trúng `FFE2` (log debug) hoặc
Battery Level `2A19`, khiến app báo **đã kết nối nhưng không có dữ liệu**. Nay:

1. **Chọn kênh tất định** (`Sources/BMSCore/Acquisition.swift`): ưu tiên
   `FFE1` (JK), `FF01`/`FF02` (JBD), `FFF1`/`FFF2` (Daly); bỏ `FFE2` và GATT chuẩn.
2. **Chờ CCCD xác nhận notify/indicate rồi mới gửi lệnh** (tối đa 5 s), có thử
   kênh kế tiếp và fallback `read` định kỳ.
3. **Chỉ đẩy dữ liệu của đúng kênh đã chọn** vào parser.
4. **Kiểm tra khung nghiêm ngặt** trước khi giải mã (JK CRC8, ANT checksum 16-bit,
   Daly checksum/cmd, JBD cmd/len/trailer + kiểm tra hợp lý) và **khóa hãng**
   sau khung hợp lệ đầu tiên.
5. **Watchdog phân biệt** "không nhận byte nào" / "có byte nhưng sai khung" /
   "có khung nhưng mất nhịp"; màn hình chẩn đoán hiển thị kênh đã chọn, số gói,
   số byte và số khung hợp lệ.
6. **UI chỉ hiển thị trường thực sự có trong khung** (provenance), không biến
   giá trị mặc định của decoder thành dữ liệu mạch thật.

Kết nối lại dùng `CBPeripheral.identifier` (iOS không cho MAC); kết nối có
timeout 12 s và tự dọn state khi ngắt.

> Đây là bản sửa cho lỗi "kết nối được nhưng không có dữ liệu" trên JK-BMS.
> Logic đã có unit test và golden vectors; vẫn cần xác nhận lại trên mạch JK
> thật (Phase 8) — xem mục **Chẩn đoán** trong app để biết kênh đã chọn.

## Chỉ hiện mạch BMS khi quét (giống app của hãng)

App của JK/JBD/Daly thường không liệt kê mọi thiết bị Bluetooth quanh đó. Họ
lọc ngay từ gói quảng cáo theo một trong các dấu hiệu:

- **tên thiết bị** (tiền tố/thương hiệu: `JK`, `JBD`, `Xiaoxiang`, `Daly`, `ANT`…),
- **service UUID 16-bit đặc trưng** được quảng cáo (`FFE0` cho JK/ANT,
  `FF00` cho JBD, `FFF0` cho Daly),
- **company/manufacturer ID** trong gói quảng cáo,
- gọi `scanForPeripherals(withServices:)` để iOS lọc hộ.

iOS không cho đọc MAC và nhiều mạch không quảng cáo service UUID, nên app này
quét tất cả rồi lọc bằng phần mềm trong `BMSScanFilter`:

1. tên khớp hãng đã biết → chắc chắn (điểm 100);
2. tên chứa từ khóa `bms`, `lifepo4`, `battery monitor`… → điểm 80;
3. service `FF00`/`FFF0` → đúng hãng (điểm 90);
4. service `FFE0` → "có thể là JK/ANT" (điểm 70, vì nhiều module BLE giá rẻ
   cũng dùng service này);
5. còn lại → ẩn khỏi danh sách.

Màn hình **Quét & kết nối** có công tắc **“Hiện tất cả thiết bị Bluetooth”**
cho trường hợp mạch đã được đổi tên lạ, kèm số thiết bị đã ẩn và lý do từng
thiết bị được nhận là BMS.



## Hai trạng thái màn hình chính

**Chưa kết nối** — không còn dữ liệu mẫu hay card rỗng:

- Nút **Kết nối BLE** ở giữa màn hình, vòng radar lan toả phía sau.
- Dòng trạng thái BLE (đang quét / đang kết nối / Bluetooth tắt / lỗi) ngay
  dưới nút; lỗi BLE gần nhất hiển thị dạng banner.
- Bấm nút mở **Quét & kết nối**.

**Đã kết nối** — header gọn + danh sách thông tin:

- **Header**: chấm trạng thái BLE, tên thiết bị, dòng trạng thái, các chip
  (giao thức, số cell, cách đọc, tuổi dữ liệu) và nút **Ngắt**.
- **Chờ dữ liệu**: nếu chưa có khung hợp lệ, card amber/đỏ hiện ngay dưới
  header với chẩn đoán kênh và số byte nhận được.
- **Mạch BMS**: hãng, giao thức, cell cấu hình / cell đọc được, cách đọc.
- **Thông tin thiết bị**: tên, model, serial, ngày sản xuất, phiên bản HW/SW,
  dữ liệu người dùng, thời gian chạy + số lần bật.
- **Mật khẩu**: PIN BLE, mật khẩu cài đặt, mật khẩu kết nối — ẩn mặc định,
  nhấn 👁 để hiện, nhấn biểu tượng để sao chép (có phản hồi rung).
- Chỉ hiển thị trường thực sự có trong khung nhận được (dựa trên provenance),
  trường thiếu để trống thay vì bịa giá trị mặc định.
- Cảnh báo bit lỗi từ mạch và lỗi BLE hiển thị dạng banner.
- Chuyển động: khi vừa kết nối, header và từng card lần lượt **bung ra** từ
  phía nút kết nối (`burstOut`, so le theo index), quầng sáng trôi chậm, giá
  trị đổi mượt; tự tắt khi bật *Reduce Motion*.

## Roadmap

- [x] Phase 1 — golden vectors + đặc tả (`docs/protocol.md`)
- [x] Phase 3 — parser Swift + tests (chạy trên CI hoặc `swift test` local)
- [x] Phase 4 — BLESession (quét/kết nối/heartbeat; test với mạch thật tại Phase 8)
- [x] Phase 5 — UI dữ liệu tối giản: mạch + thiết bị + mật khẩu (animation smooth)
- [x] Lọc quét: chỉ hiện mạch BMS (tên hãng + service UUID), có công tắc hiện tất cả
- [x] App icon (`App/Assets.xcassets`) + bundle ID `vn.ngia.bmsreader`
- [ ] Phase 6 — nhớ thiết bị (UUID), settings
- [ ] Phase 7 — ổn định iOS (quyền, lỗi, background)
- [ ] Phase 8 — test với mạch thật từng hãng
- [ ] Phase 9 — close-out: đã quy trình re-sign, README hoàn chỉnh