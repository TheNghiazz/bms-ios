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
│  └─ Features/Scan/ScanSheet.swift
├─ tools/gen_golden_vectors.py    sinh golden vectors từ code Python gốc
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
- **Sinh lại golden vectors** (sau khi sửa parser Python gốc):
  ```
  python tools/gen_golden_vectors.py
  ```

## Chế độ demo trong app

Mở app là dữ liệu mẫu ANT 17S 60V/30Ah hiển thị sẵn (giống hành vi GUI gốc),
menu có thêm mẫu JK 24S, JK 32S, JBD, Daly. Từ đây có thể kiểm toàn bộ số
liệu HIỂN THỊ trước khi cắm mạch thật.

## Roadmap

- [x] Phase 1 — golden vectors + đặc tả (`docs/protocol.md`)
- [x] Phase 3 — parser Swift + tests (chạy trên CI hoặc `swift test` local)
- [x] Phase 4 — BLESession (quét/kết nối/heartbeat; test với mạch thật tại Phase 8)
- [x] Phase 5 — dashboard UI v1 (Phase 6 nâng cấp chỉnh theo bản Tkinter)
- [ ] Phase 6 — nhớ thiết bị (UUID), settings, icon
- [ ] Phase 7 — ổn định iOS (quyền, lỗi, background)
- [ ] Phase 8 — test với mạch thật từng hãng
- [ ] Phase 9 — close-out: đã quy trình re-sign, README hoàn chỉnh