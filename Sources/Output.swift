import Foundation
import CoreGraphics

struct OutputRecord: Codable, Equatable {
    let words: [UInt32]
    // SkyLight link descriptors for this inspected OS: bpc, full range, HDR, YCbCr.
    // Confirm every actual write against the independent IOAV video readback.
    var target: Bool { words == [10, 1, 0, 0] }
}
func withSkyLight<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    guard v.majorVersion == 26 && v.minorVersion == 6 && v.patchVersion == 2,
          let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { throw NetError("Bu macOS sürümünün renk API'si doğrulanmadı.") }
    defer { dlclose(h) }; return try body(h)
}
func outputModes(_ id: CGDirectDisplayID, mode: ModeRecord) throws -> (options: [OutputRecord], current: OutputRecord?) {
    try withSkyLight { h in
        typealias Count = @convention(c) (UInt32, UInt64, UnsafeMutablePointer<UInt32>) -> Int32
        typealias Describe = @convention(c) (UInt32, UInt64, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32
        guard mode.id >= 0, let c = dlsym(h,"SLSGetDisplayOutputModeCount"), let d = dlsym(h,"SLSGetDisplayOutputModeLinkDescriptions") else { throw NetError("Renk listeleme API'si yok.") }
        let countFn = unsafeBitCast(c,to:Count.self), describe = unsafeBitCast(d,to:Describe.self)
        var count: UInt32 = 0
        guard countFn(id,UInt64(mode.id),&count) == 0, count > 0, count <= 256 else { throw NetError("Uyumlu renk modu listesi okunamadı.") }
        let capacity = count
        var buffer = [UInt32](repeating: 0, count: Int(count)*4), current: UInt32 = .max
        let result = buffer.withUnsafeMutableBytes { describe(id,UInt64(mode.id),$0.baseAddress!,&count,&current) }
        guard result == 0, count <= capacity else { throw NetError("Renk modu açıklamaları okunamadı.") }
        let options = (0..<Int(count)).map { OutputRecord(words: Array(buffer[($0*4)..<($0*4+4)])) }
        return (options, current < count ? options[Int(current)] : nil)
    }
}
func configureOutput(_ record: OutputRecord, mode: ModeRecord, id: CGDirectDisplayID, config: CGDisplayConfigRef?) throws {
    let options = try outputModes(id, mode: mode).options
    let matches = options.indices.filter { options[$0] == record }
    guard matches.count == 1, record.words.count == 4 else { throw NetError("Kaydedilen renk modu artık tekil olarak sunulmuyor; yaklaşık mod seçilmedi.") }
    try withSkyLight { h in
        typealias Configure = @convention(c) (OpaquePointer?, UInt32, UInt64, UInt64) -> Int32
        guard let s = dlsym(h,"SLSConfigureDisplayOutputMode") else { throw NetError("Renk uygulama API'si yok.") }
        let f = unsafeBitCast(s,to:Configure.self)
        // The final two ABI registers carry the 16-byte description BY VALUE,
        // not the display-mode index and output-list index.
        let first = UInt64(record.words[0]) | (UInt64(record.words[1]) << 32)
        let second = UInt64(record.words[2]) | (UInt64(record.words[3]) << 32)
        let result = f(config,id,first,second)
        guard result == 0 else { throw NetError("Sistem renk modunu reddetti: \(result)") }
    }
}
