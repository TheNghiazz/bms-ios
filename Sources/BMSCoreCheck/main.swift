// main.swift
// Chạy kiểu thực thi đơn giản để kiểm tra golden vectors bằng
// `swift run bmscore-check` (hữu ích trên Windows/Linux, nơi XCTest có thể
// chưa khả dụng). CI trên macOS cũng chạy `swift test`.

import BMSCore
import Foundation

#if canImport(Darwin)
import Darwin
#else if canImport(Glibc)
import Glibc
#else if canImport(ucrt)
import ucrt
#endif

var failures = GoldenVectorCheck.runAll(mode: .separate)
    + GoldenVectorCheck.runAll(mode: .chunked)

let caseCount = GoldenVectorCheck.caseCount()
if failures.isEmpty {
    print("PASS: golden vectors OK — \(caseCount) case, 2 chế độ feed.")
    exit(0)
} else {
    var out = "FAIL: golden vectors — \(failures.count) vấn đề trong \(caseCount) case:"
    for fail in failures.prefix(20) {
        out += "\n  - " + fail
    }
    if failures.count > 20 { out += "\n  ... và còn \(failures.count - 20) lỗi khác" }
    print(out)
    exit(1)
}
