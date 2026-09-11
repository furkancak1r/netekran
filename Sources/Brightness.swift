import AppKit
import CoreGraphics
import IOKit

final class BrightnessControl: NSObject {
    let builtIn: Bool
    let canChange: () -> Bool
    private let queue = DispatchQueue(label: "tr.netekran.brightness", qos: .userInitiated)
    private var reading: BrightnessReading?
    private var failure: String?
    private var busy = false
    private var desired: Double?
    private var automaticDesired: Bool?
    private var generation = 0
    private var debounce: DispatchWorkItem?
    private var slider: NSSlider?
    private var label: NSTextField?
    private var automaticItem: NSMenuItem?
    private var title: String { builtIn ? "Mac ekranı" : "Harici monitör" }

    init(builtIn: Bool, canChange: @escaping () -> Bool) {
        self.builtIn = builtIn; self.canChange = canChange
    }
    func add(to menu: NSMenu) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 60))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 16, y: 34, width: 298, height: 20)
        label.font = NSFont.systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(change(_:)))
        slider.frame = NSRect(x: 16, y: 8, width: 298, height: 24)
        slider.isContinuous = true; slider.setAccessibilityLabel(title + " parlaklığı")
        view.addSubview(label); view.addSubview(slider)
        self.label = label; self.slider = slider
        let item = NSMenuItem(); item.view = view; menu.addItem(item)
        if builtIn {
            let item = NSMenuItem(title: "Otomatik parlaklık (Mac ekranı)", action: #selector(toggleAutomatic), keyEquivalent: "")
            item.target = self; menu.addItem(item); automaticItem = item
        }
        update()
    }
    private func update() {
        let value = desired ?? reading?.percent
        slider?.isEnabled = canChange() && reading != nil && automaticDesired == nil
        if let value { slider?.doubleValue = value }
        let status = failure ?? value.map { "%\(Int($0.rounded()))" } ?? "Parlaklık okunuyor…"
        label?.stringValue = title + ": " + status
        label?.toolTip = label?.stringValue
        slider?.setAccessibilityValueDescription(value.map { "%\(Int($0.rounded()))" } ?? "Okunamadı")
        automaticItem?.isEnabled = canChange() && !busy && desired == nil && reading?.automatic != nil
        automaticItem?.state = reading?.automatic.map { $0 ? .on : .off } ?? .mixed
        automaticItem?.toolTip = reading?.automatic == nil ? "Otomatik parlaklık desteklenmiyor veya okunamadı." : nil
    }
    @objc private func change(_ sender: NSSlider) {
        guard canChange(), reading != nil, automaticDesired == nil else { return }
        desired = sender.doubleValue; generation += 1; failure = nil; update()
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }; debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    @objc private func toggleAutomatic() {
        guard canChange(), !busy, desired == nil, let current = reading?.automatic else { return }
        automaticDesired = !current; generation += 1; refresh()
    }
    func refresh() {
        guard !busy, canChange() else { update(); return }
        let percent = desired, automatic = automaticDesired, generation = generation
        busy = true; update()
        queue.async {
            let result = Result { try runBrightnessRequest(percent: percent, builtIn: self.builtIn, automatic: automatic) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let reading): self.reading = reading; self.failure = nil
                case .failure(let error): self.reading = nil; self.failure = error.localizedDescription
                }
                if self.generation == generation { self.desired = nil; self.automaticDesired = nil }
                self.update()
                if self.desired != nil || self.automaticDesired != nil { self.refresh() }
            }
        }
    }
}

struct BrightnessReading: Codable, Equatable {
    let current: Int
    let maximum: Int
    var automatic: Bool? = nil
    var percent: Double { Double(current) * 100 / Double(maximum) }
}

func brightnessValue(percent: Double, maximum: Int) throws -> Int {
    guard percent.isFinite, (0...100).contains(percent), (1...65535).contains(maximum) else {
        throw NetError("Parlaklık 0–100 arasında olmalı.")
    }
    return Int((percent * Double(maximum) / 100).rounded())
}

func builtInBrightnessRequest(percent: Double? = nil, automatic: Bool? = nil) throws -> BrightnessReading {
    if let percent { _ = try brightnessValue(percent: percent, maximum: 100) }
    guard percent == nil || automatic == nil else { throw NetError("Tek parlaklık ayarı seçin.") }
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { throw NetError("Mac ekranı bulunamadı.") }
    let builtIn = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    guard builtIn.count == 1, let id = builtIn.first, CGDisplayIsAsleep(id) == 0 else {
        throw NetError("Yerleşik ekran kapalı veya bağlı değil.")
    }
    guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
        throw NetError("macOS parlaklık kontrolü kullanılamıyor.")
    }
    defer { dlclose(library) }
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias Has = @convention(c) (CGDirectDisplayID) -> Bool
    typealias GetAuto = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    typealias SetAuto = @convention(c) (CGDirectDisplayID, Bool) -> Int32
    guard let getSymbol = dlsym(library, "DisplayServicesGetBrightness"),
          let setSymbol = dlsym(library, "DisplayServicesSetBrightness") else {
        throw NetError("macOS parlaklık kontrolü desteklenmiyor.")
    }
    let get = unsafeBitCast(getSymbol, to: Get.self), set = unsafeBitCast(setSymbol, to: Set.self)
    func readAuto() -> Bool? {
        guard let hasSymbol = dlsym(library, "DisplayServicesHasAmbientLightCompensation"),
              unsafeBitCast(hasSymbol, to: Has.self)(id),
              let symbol = dlsym(library, "DisplayServicesAmbientLightCompensationEnabled") else { return nil }
        var value = false
        return unsafeBitCast(symbol, to: GetAuto.self)(id, &value) == 0 ? value : nil
    }
    func read() throws -> BrightnessReading {
        var value: Float = .nan
        guard get(id, &value) == 0, value.isFinite, (0...1).contains(value) else {
            throw NetError("Mac ekranının parlaklığı okunamadı.")
        }
        return BrightnessReading(current: Int((Double(value) * 10000).rounded()), maximum: 10000, automatic: readAuto())
    }
    let before = try read()
    if let automatic {
        guard before.automatic != nil, let symbol = dlsym(library, "DisplayServicesEnableAmbientLightCompensation") else {
            throw NetError("Otomatik parlaklık desteklenmiyor veya okunamadı.")
        }
        guard unsafeBitCast(symbol, to: SetAuto.self)(id, automatic) == 0 else {
            throw NetError("Otomatik parlaklık değiştirilemedi.")
        }
    } else if let percent {
        guard set(id, Float(percent / 100)) == 0 else { throw NetError("Mac ekranının parlaklığı değiştirilemedi.") }
    } else { return before }
    // ponytail: short readback polling handles the system's asynchronous update; the parent bounds the whole request.
    for _ in 0..<10 {
        Thread.sleep(forTimeInterval: 0.05)
        let after = try read()
        if let automatic, after.automatic == automatic { return after }
        if let percent, abs(after.percent - percent) <= 1 { return after }
    }
    throw NetError("macOS parlaklık değişimini doğrulamadı; menüyü yeniden açın.")
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

func runBrightnessRequest(percent: Double?, builtIn: Bool = false, automatic: Bool? = nil) throws -> BrightnessReading {
    if let percent { _ = try brightnessValue(percent: percent, maximum: 100) }
    guard automatic == nil || (builtIn && percent == nil) else { throw NetError("Geçersiz otomatik parlaklık isteği.") }
    let process = Process(), output = Pipe(), errors = Pipe()
    process.executableURL = Bundle.main.executableURL
    let prefix = builtIn ? "--builtin-brightness" : "--brightness"
    process.arguments = automatic.map { ["--builtin-auto-brightness", $0 ? "on" : "off"] }
        ?? percent.map { [prefix + "-set", String($0)] } ?? [prefix + "-read"]
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
