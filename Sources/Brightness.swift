import Foundation
import CoreGraphics
import IOKit

struct BrightnessReading: Codable, Equatable {
    let current: Int
    let maximum: Int
    var percent: Double { Double(current) * 100 / Double(maximum) }
}

func brightnessValue(percent: Double, maximum: Int) throws -> Int {
    guard percent.isFinite, (0...100).contains(percent), (1...65535).contains(maximum) else {
        throw NetError("Parlaklık 0–100 arasında olmalı.")
    }
    return Int((percent * Double(maximum) / 100).rounded())
}

func brightnessPacket(value: Int? = nil) -> [UInt8] {
    // DDC/CI VCP 0x10. Include the host/source address in both request checksums.
    var bytes: [UInt8] = value.map { [0x84, 0x03, 0x10, UInt8($0 >> 8), UInt8($0 & 255)] } ?? [0x82, 0x01, 0x10]
    bytes.append(bytes.reduce((0x6e ^ 0x51), ^))
    return bytes
}

func decodeBrightness(_ bytes: [UInt8]) throws -> BrightnessReading {
    guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88, bytes[2] == 0x02,
          bytes[3] == 0, bytes[4] == 0x10, bytes[5] == 0,
          bytes.reduce(UInt8(0x50), ^) == 0 else {
        throw NetError("Monitör DDC parlaklık yanıtını doğrulamadı; DDC/CI ayarını kontrol edin.")
    }
    let maximum = Int(bytes[6]) * 256 + Int(bytes[7]), current = Int(bytes[8]) * 256 + Int(bytes[9])
    guard maximum > 0, current <= maximum else { throw NetError("Monitör geçersiz parlaklık aralığı bildirdi.") }
    return BrightnessReading(current: current, maximum: maximum)
}

func brightnessRequest(percent: Double?) throws -> BrightnessReading {
    if let percent { _ = try brightnessValue(percent: percent, maximum: 100) }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    guard version.majorVersion == 26, version.minorVersion == 6, version.patchVersion == 2 else {
        throw NetError("Bu macOS sürümünde DDC parlaklık kontrolü doğrulanmadı.")
    }
    try prepareStorage()
    let lock = open(dataDirectory.appendingPathComponent("transaction.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw NetError("Ekran işlem kilidi açılamadı.") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NetError("Ekran ayarı uygulanıyor; parlaklık için biraz bekleyin.") }
    let id = try targetDisplay()
    guard CGDisplayIsAsleep(id) == 0 else { throw NetError("Parlaklık için monitörü uyandırın.") }
    let linkStatus = ioavLinkReport()["status"] as? String ?? "unavailable"
    guard ["linkRead", "videoColorVerified"].contains(linkStatus) else {
        throw NetError("Monitör bağlantısı hazır değil; ekranı uyandırın veya HDMI kablosunu kontrol edin.")
    }
    guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { throw NetError("DDC arabirimi açılamadı.") }
    defer { dlclose(library) }
    typealias Create = @convention(c) (CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    typealias EDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32
    typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    guard let c = dlsym(library, "IOAVServiceCreateWithService"), let e = dlsym(library, "IOAVServiceCopyEDID"),
          let w = dlsym(library, "IOAVServiceWriteI2C"), let r = dlsym(library, "IOAVServiceReadI2C") else {
        throw NetError("DDC parlaklık sembolleri bulunamadı.")
    }
    let create = unsafeBitCast(c, to: Create.self), edid = unsafeBitCast(e, to: EDID.self)
    let write = unsafeBitCast(w, to: I2C.self), read = unsafeBitCast(r, to: I2C.self)
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
        throw NetError("Monitör DDC servisi bulunamadı.")
    }
    defer { IOObjectRelease(iterator) }
    var candidates: [CFTypeRef] = []
    while true {
        let entry = IOIteratorNext(iterator); if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        guard let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
        var data: Unmanaged<CFData>?
        if edid(service, &data) == 0, let bytes = data?.takeRetainedValue() as Data?, validTargetEDID(bytes) {
            candidates.append(service)
        }
    }
    guard candidates.count == 1 else { throw NetError("Tek hedef monitör DDC servisi doğrulanamadı.") }
    let service = candidates[0]
    func send(_ packet: [UInt8]) throws {
        var packet = packet
        let result = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
        guard result == 0 else { throw NetError("Monitör DDC isteğini kabul etmedi (\(result)).") }
    }
    func get() throws -> BrightnessReading {
        try send(brightnessPacket())
        Thread.sleep(forTimeInterval: 0.05)
        var reply = [UInt8](repeating: 0, count: 11)
        let result = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
        guard result == 0 else { throw NetError("Monitör parlaklığı okunamadı (\(result)); DDC/CI açık olmalı.") }
        return try decodeBrightness(reply)
    }
    let before = try get()
    guard let percent else { return before }
    let value = try brightnessValue(percent: percent, maximum: before.maximum)
    if value == before.current { return before }
    try send(brightnessPacket(value: value))
    Thread.sleep(forTimeInterval: 0.05)
    let after = try get()
    guard after.current == value, after.maximum == before.maximum else { throw NetError("Monitör istenen parlaklığı doğrulamadı.") }
    return after
}

func runBrightnessRequest(percent: Double?) throws -> BrightnessReading {
    let process = Process(), output = Pipe(), errors = Pipe()
    process.executableURL = Bundle.main.executableURL
    process.arguments = percent.map { ["--brightness-set", String($0)] } ?? ["--brightness-read"]
    process.standardOutput = output; process.standardError = errors
    try process.run()
    guard waitForWorker(process, timeout: 3) else {
        _ = stopWorker(process)
        throw NetError("Monitör parlaklık isteğine zamanında yanıt vermedi.")
    }
    guard process.terminationStatus == 0 else {
        let reason = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw NetError(reason?.isEmpty == false ? reason! : "Parlaklık ayarlanamadı.")
    }
    let reading = try JSONDecoder().decode(BrightnessReading.self, from: output.fileHandleForReading.readDataToEndOfFile())
    guard (1...65535).contains(reading.maximum), (0...reading.maximum).contains(reading.current) else { throw NetError("Geçersiz parlaklık yanıtı.") }
    return reading
}
