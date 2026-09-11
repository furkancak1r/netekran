import AppKit
import CoreGraphics
import IOKit

func dimmingOpacity(percent: Double) throws -> Double {
    guard percent.isFinite, (15...100).contains(percent) else { throw NetError("Yazılımsal parlaklık %15–100 arasında olmalı.") }
    return 1 - percent / 100
}

final class MonitorDimmer: NSObject {
    // ponytail: dimming lasts only while this window exists; persistence can later store the percentage by display UUID.
    private var window: NSPanel?
    private var displayIdentity: String?
    private(set) var percent: Double = 100

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func screen() throws -> NSScreen {
        let id = try targetDisplay()
        guard CGDisplayIsAsleep(id) == 0, let uuid = identity(id),
              displayIdentity == nil || displayIdentity == uuid,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else {
            throw NetError("Harici ekran bağlı veya uyanık değil.")
        }
        return screen
    }
    func apply(_ value: Double) throws {
        let opacity = try dimmingOpacity(percent: value)
        if value == 100 { window?.orderOut(nil); percent = 100; return }
        let screen = try screen()
        if window == nil {
            let id = try targetDisplay(); displayIdentity = identity(id)
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "NetEkran monitör karartma"
            panel.isReleasedWhenClosed = false; panel.backgroundColor = .black
            panel.isOpaque = false; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window = panel
        }
        window?.setFrame(screen.frame, display: true)
        window?.alphaValue = opacity; window?.orderFrontRegardless(); percent = value
    }
    @objc private func reposition() {
        guard window != nil else { return }
        do { _ = try screen(); try apply(percent) }
        catch { window?.orderOut(nil) }
    }
    deinit { NotificationCenter.default.removeObserver(self); window?.close() }
}

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
    private lazy var dimmer = MonitorDimmer()
    private var software = false
    private var ddcFailure: String?
    private var title: String { builtIn ? "Mac ekranı" : software ? "Harici monitör (yazılımsal)" : "Harici monitör" }

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
        slider?.isEnabled = canChange() && reading != nil && automaticDesired == nil && !(software && busy)
        slider?.minValue = software ? 15 : 0
        if let value { slider?.doubleValue = value }
        let status = failure ?? value.map { "%\(Int($0.rounded()))" } ?? "Parlaklık okunuyor…"
        label?.stringValue = title + ": " + status
        label?.toolTip = software ? "DDC/CI kullanılamıyor. Görüntü yazılımsal karartılır; fiziksel arka ışık değişmez. Donanımı yeniden denemek için %100'e getirip menüyü yeniden açın.\n" + (ddcFailure ?? "") : label?.stringValue
        slider?.setAccessibilityLabel(title + " parlaklığı")
        slider?.setAccessibilityValueDescription(value.map { "%\(Int($0.rounded()))" } ?? "Okunamadı")
        automaticItem?.isEnabled = canChange() && !busy && desired == nil && reading?.automatic != nil
        automaticItem?.state = reading?.automatic.map { $0 ? .on : .off } ?? .mixed
        automaticItem?.toolTip = reading?.automatic == nil ? "Otomatik parlaklık desteklenmiyor veya okunamadı." : nil
    }
    @objc private func change(_ sender: NSSlider) {
        guard canChange(), reading != nil, automaticDesired == nil else { return }
        desired = sender.doubleValue; generation += 1; failure = nil; update()
        if software { refresh(); return }
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
        if software && (desired != nil || dimmer.percent < 100) {
            do {
                _ = try dimmer.screen()
                try dimmer.apply(desired ?? dimmer.percent)
                reading = BrightnessReading(current: Int(dimmer.percent.rounded()), maximum: 100); failure = nil
            } catch { reading = nil; failure = error.localizedDescription }
            desired = nil; update(); return
        }
        let percent = desired, automatic = automaticDesired, generation = generation
        busy = true; update()
        queue.async {
            let result = Result { try runBrightnessRequest(percent: percent, builtIn: self.builtIn, automatic: automatic) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let reading): self.reading = reading; self.failure = nil; self.software = false
                case .failure(let error):
                    if !self.builtIn, percent == nil, (try? self.dimmer.screen()) != nil {
                        self.software = true; self.ddcFailure = error.localizedDescription
                        self.reading = BrightnessReading(current: Int(self.dimmer.percent.rounded()), maximum: 100)
                        self.failure = nil; self.desired = nil
                    } else { self.reading = nil; self.failure = error.localizedDescription }
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

func readDDCBrightness(send: () -> Int32, receive: () -> (Int32, [UInt8]), pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) throws -> BrightnessReading {
    var status: Int32 = 0
    for _ in 0..<3 {
        pause()
        status = send()
        pause()
        let (readStatus, bytes) = receive()
        // Some bridges report a send error but still deliver the reply. Only a complete validated reply counts.
        if readStatus == 0, let reading = try? decodeBrightness(bytes) { return reading }
        if readStatus != 0 { status = readStatus }
    }
    let reason = status == 0 ? "Yanıt doğrulanamadı." : "İletişim hatası \(String(format: "0x%08x", status))."
    throw NetError("DDC/CI yanıtı alınamadı; monitör menüsünde DDC/CI'yi kontrol edin. " + reason)
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
        try readDDCBrightness(send: {
            var packet = brightnessPacket()
            return packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
        }, receive: {
            var reply = [UInt8](repeating: 0, count: 11)
            let result = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            return (result, reply)
        })
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
