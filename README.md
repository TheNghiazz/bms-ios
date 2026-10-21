# BMS Monitor — iOS (SwiftUI + CoreBluetooth)

Port từ `universal_bms_ble_reader.py` (Tkinter + bleak, Windows) sang app iOS
đọc BMS qua Bluetooth BLE: **JK-BMS · ANT-BMS · JBD/Xiaoxiang · Daly**.
Logic giải mã được port ra **Swift Package thuần (`BMSCore`)** và đối chiếu
số liệu bằng **golden vectors** sinh từ chính code Python gốc.

## Cấu trúc

```
bms-ios/
├─ Package.swift                  BMSCore (thuần Swift, test được Everywhere)
├─ Sources/BMSCore/               parser + 4 decoder + golden check
│  └─ Resources/golden_vectors.json
├─ Sources/BMSCoreCheck/main.swift  chạy check kiểu executable (swift run)
├─ Tests/BMSCoreTests/            XCTest
├─ App/                           SwiftUI app (iOS 17+)
│  ├─ BMSMonitorApp.swift         @main + RootView
│  ├─ BMSStore.swift              trạng thái chung (parser + session)
│  ├─ BLE/BLESession.swift        CoreBluetooth: quét/kết nối/heartbeat
│  ├─ Features/Dashboard/         dashboard live: ETA, SOC, cell grid
│  ├─ Features/Scan/ScanSheet.swift
│  ├─ Features/Lock/              khoá app bằng mật khẩu (mặc định "ngia")
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

## Chế độ demo trong app

Mở app là dữ liệu mẫu ANT 17S 60V/30Ah hiển thị sẵn (giống hành vi GUI gốc),
menu có thêm mẫu JK 24S, JK 32S, JBD, Daly. Từ đây có thể kiểm toàn bộ số
liệu HIỂN THỊ trước khi cắm mạch thật.

## Khoá app bằng mật khẩu

- App hỏi mật khẩu ngay khi mở. **Mật khẩu mặc định lần đầu: `ngia`**
  (màn hình khoá hiện gợi ý này chừng nào chưa đổi).
- **Tự khoá khi app xuống background** (app switcher, thoát ra), chỉ dùng
  `.background` nên hộp thoại xin quyền Bluetooth / Control Center không khoá
  giữa chừng.
- **Sai 5 lần liên tiếp → tạm khoá 30 giây** (có đếm ngược; trạng thái được
  lưu nên thoát app rồi mở lại vẫn phải chờ đủ).
- Đổi mật khẩu: menu **⋯ → Đổi mật khẩu** (cần nhập mật khẩu hiện tại,
  mật khẩu mới tối thiểu 4 ký tự). **⋯ → Khoá app** để khoá lại ngay.
- Chỉ lưu `SHA-256(salt + mật khẩu)` trong `UserDefaults`, không lưu mật khẩu
  gốc và không dùng Keychain (tránh mất quyền truy cập sau khi re-sign bằng
  Apple ID free).
- Quên mật khẩu: xoá app rồi cài lại — mật khẩu (và settings) về mặc định.
  Đây là lớp chặn mở app, không mã hoá dữ liệu BMS.

## Roadmap

- [x] Phase 1 — golden vectors + đặc tả (`docs/protocol.md`)
- [x] Phase 3 — parser Swift + tests (chạy trên CI hoặc `swift test` local)
- [x] Phase 4 — BLESession (quét/kết nối/heartbeat; test với mạch thật tại Phase 8)
- [x] Phase 5 — dashboard UI v1 (Phase 6 nâng cấp chỉnh theo bản Tkinter)
- [x] App icon (`App/Assets.xcassets`) + bundle ID `vn.ngia.bmsreader`
- [x] Khoá app bằng mật khẩu (mặc định `ngia`, tự khoá khi background, chặn 5 lần sai)
- [ ] Phase 6 — nhớ thiết bị (UUID), settings
- [ ] Phase 7 — ổn định iOS (quyền, lỗi, background)
- [ ] Phase 8 — test với mạch thật từng hãng
- [ ] Phase 9 — close-out: đã quy trình re-sign, README hoàn chỉnh