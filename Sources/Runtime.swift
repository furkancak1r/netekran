import AppKit
import CoreGraphics
import ColorSync

let targetVendor: UInt32 = 13441
let targetProduct: UInt32 = 568
let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NetEkran", isDirectory: true)

struct NetError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}
func prepareStorage() throws {
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}
func identity(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}
func targetDisplay() throws -> CGDirectDisplayID {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { throw NetError("WindowServer ekran listesi okunamadı.") }
    let matches = ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) == targetVendor && CGDisplayModelNumber($0) == targetProduct && CGDisplayIsBuiltin($0) == 0 }
    guard matches.count == 1 else { throw NetError(matches.isEmpty ? "GB-2411FF bağlı değil veya ekran oturumuna erişilemiyor." : "Birden fazla GB-2411FF var; yanlış ekranı değiştirmemek için işlem durduruldu.") }
    return matches[0]
}
struct ModeRecord: Codable, Equatable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshHz: Double
    let flags: UInt32
    init(_ mode: CGDisplayMode) {
        id = mode.ioDisplayModeID; width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight; refreshHz = mode.refreshRate; flags = mode.ioFlags
    }
    var exactGeometry: Bool { width == 1920 && height == 1080 && pixelWidth == 3840 && pixelHeight == 2160 && abs(refreshHz - 100) < 0.1 }
}
func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
}
func currentMode(_ id: CGDirectDisplayID) throws -> ModeRecord {
    guard let m = CGDisplayCopyDisplayMode(id) else { throw NetError("Geçerli çizim modu okunamadı.") }
    return ModeRecord(m)
}
func currentProfile(_ id: CGDirectDisplayID) throws -> DisplayProfile {
    let m = try currentMode(id)
    let color = ioavLinkReport()["color"] as? [String: Any] ?? [:]
    return DisplayProfile(logicalWidth: m.width, logicalHeight: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refreshHz: m.refreshHz, bitDepth: color["bitDepth"] as? Int, hdr: color["hdr"] as? Bool, encoding: color["encoding"] as? String, fullRange: color["fullRange"] as? Bool, mirrored: CGDisplayIsInMirrorSet(id) != 0, identity: identity(id) ?? "")
}
func applyMode(_ record: ModeRecord, uuid: String, output: OutputRecord? = nil) throws {
    let id = try targetDisplay()
    guard identity(id) == uuid, CGDisplayIsAsleep(id) == 0, CGDisplayIsInMirrorSet(id) == 0 else { throw NetError("Ekran kimliği değişti, ekran uyuyor veya yansıtma açık; değişiklik yapılmadı.") }
    // Mode IDs are valid only after re-resolving the stable UUID and all mode properties.
    guard let mode = modes(id).first(where: { ModeRecord($0) == record }) else { throw NetError("Kaydedilen mod artık sunulmuyor; yaklaşık moda geçilmedi.") }
    let needsModeChange = try currentMode(id) != record
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { throw NetError("Ekran işlemi başlatılamadı.") }
    if needsModeChange {
        let set = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        guard set == .success else { CGCancelDisplayConfiguration(config); throw NetError("Ekran modu reddedildi: \(set.rawValue)") }
    }
    do { if let output { try configureOutput(output, mode: record, id: id, config: config) } }
    catch { CGCancelDisplayConfiguration(config); throw error }
    let complete = CGCompleteDisplayConfiguration(config, .forSession)
    guard complete == .success else { throw NetError("Ekran işlemi tamamlanamadı: \(complete.rawValue)") }
    guard try currentMode(id) == record else { throw NetError("Sistem istenen gerçek çizim modunu doğrulamadı.") }
}
struct Transaction: Codable {
    let uuid: String
    let previous: ModeRecord
    let proposed: ModeRecord
    var preserved: [String: String]? = nil
    var previousOutput: OutputRecord? = nil
    var proposedOutput: OutputRecord? = nil
    var previousColorData: String? = nil
    var proposedColorData: String? = nil
    var previousICC: ICCSelection? = nil
    var proposedICC: ICCSelection? = nil
    var automatic: Bool? = nil
    var expectedAfter: [String: String]? = nil
}
struct TransactionState: Codable {
    let status: String
    let message: String
}
func state(_ dir: URL, _ status: String, _ message: String) throws {
    try writeJSON(TransactionState(status: status, message: message), to: dir.appendingPathComponent("state.json"))
}
func rollback(_ tx: Transaction, directory: URL) {
    do {
        try applyMode(tx.previous, uuid: tx.uuid, output: tx.previousOutput)
        if let previous = tx.previousICC, let proposed = tx.proposedICC {
            let current = try iccSelection(targetDisplay())
            guard current.activeURL == previous.activeURL || current.activeURL == proposed.activeURL || current.activeURL == current.factoryURL else { throw NetError("ICC seçimi dışarıdan değişmiş; üzerine yazılmadı.") }
            let resolved = ICCSelection(profileID: current.profileID, customURL: previous.customURL, activeURL: previous.activeURL, factoryURL: current.factoryURL)
            try applyICCSelection(resolved, uuid: tx.uuid, expected: current)
        }
        if let expected = tx.previousColorData {
            let read = ioavLinkReport()["color"] as? [String: Any]
            guard read?["elementDataBase64"] as? String == expected else { throw NetError("Önceki renk çıkışı yeniden doğrulanamadı.") }
        }
        let observed = preservationReadback(try targetDisplay())
        guard (tx.preserved ?? [:]).allSatisfy({ observed[$0.key] == $0.value }) else {
            throw NetError("Çizim geri alındı ancak ICC/gamma parmak izi eşleşmedi; bu ayarlar zorla değiştirilmedi.")
        }
        try state(directory, "reverted", "Önceki çizim modu geri yüklendi.")
    } catch { try? state(directory, "recoveryRequired", "Geri alma tamamlanamadı: \(error.localizedDescription). Ekranı aynı bağlantıya takıp Önceki ayarlara dön seçeneğini kullanın.") }
}
func verifyProposedColor(_ tx: Transaction, id: CGDirectDisplayID) throws {
    guard identity(id) == tx.uuid, try currentMode(id) == tx.proposed, CGDisplayIsInMirrorSet(id) == 0 else { throw NetError("Çizim modu, ekran kimliği veya yansıtma durumu değişti.") }
    guard let output = tx.proposedOutput else { return }
    guard try outputModes(id, mode: currentMode(id)).current == output else { throw NetError("Sistemin seçili renk indeksi istenenle eşleşmedi.") }
    let link = ioavLinkReport()["color"] as? [String: Any]
    if let expected = tx.proposedColorData {
        guard link?["elementDataBase64"] as? String == expected else { throw NetError("Geri yüklenmek istenen renk çıkışı eşleşmedi.") }
        if output.target { guard assessTarget(try currentProfile(id)).matchesTarget else { throw NetError("Canlı HDMI ve çizim profili tam hedefle eşleşmedi.") } }
    } else {
        guard output.target, assessTarget(try currentProfile(id)).matchesTarget else { throw NetError("Gerçek HDMI çıkışı tam hedefle eşleşmedi; önceki profile dönülüyor.") }
    }
}
func waitForWorker(_ worker: Process, timeout: Double) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while worker.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
    return !worker.isRunning
}
func stopWorker(_ worker: Process) -> Bool {
    if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
    return waitForWorker(worker, timeout: 2)
}
func requireTransactionLock(_ url: URL = dataDirectory.appendingPathComponent("transaction.lock")) throws {
    var inherited = stat(), stored = stat()
    guard fstat(STDIN_FILENO, &inherited) == 0, lstat(url.path, &stored) == 0,
          stored.st_mode & S_IFMT == S_IFREG, inherited.st_dev == stored.st_dev, inherited.st_ino == stored.st_ino,
          flock(STDIN_FILENO, LOCK_EX | LOCK_NB) == 0 else { throw NetError("Donanım çalışanı koruyucunun işlem kilidini devralmadı.") }
}
func runWatchdog(_ directory: URL, lockURL: URL? = nil, applyTimeout: Double = 10, recoveryTimeout: Double = 10) throws {
    // This supervisor never calls a display API: a blocked hardware call must
    // not prevent it from expiring the confirmation and starting recovery.
    let lock = open((lockURL ?? dataDirectory.appendingPathComponent("transaction.lock")).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw NetError("İşlem kilidi açılamadı.") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NetError("Başka bir ekran işlemi sürüyor.") }
    guard fcntl(lock, F_SETFD, FD_CLOEXEC) == 0 else { throw NetError("İşlem kilidi yalıtılamadı.") }
    func launch(_ argument: String) throws -> Process {
        let child = Process(); child.executableURL = Bundle.main.executableURL
        // stdin deliberately carries the same open lock description: a child
        // retains exclusivity even if the supervisor is unexpectedly killed.
        child.standardInput = FileHandle(fileDescriptor: lock, closeOnDealloc: false)
        child.arguments = [argument, directory.path]; try child.run(); return child
    }
    func status() -> String? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("state.json")) else { return nil }
        return (try? JSONDecoder().decode(TransactionState.self, from: bytes))?.status
    }
    let worker = try launch("--transaction-worker")
    var deadline = ProcessInfo.processInfo.systemUptime + applyTimeout, sawConfirmation = false
    while worker.isRunning {
        if status() == "waiting" && !sawConfirmation {
            sawConfirmation = true; deadline = ProcessInfo.processInfo.systemUptime + 20
        }
        if ProcessInfo.processInfo.systemUptime >= deadline { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if !stopWorker(worker) {
        try state(directory, "recoveryRequired", "Donanım işlemi durdurulamıyor; işlem kilidi korunuyor. Otomatik geri dönüş doğrulanamadı.")
        // ponytail: a kernel-blocked child cannot be recovered in user space;
        // retain the lock until it exits, then attempt bounded recovery.
        while worker.isRunning { Thread.sleep(forTimeInterval: 0.2) }
    }
    let last = status()
    if ["kept", "reverted"].contains(last ?? "") { return }
    guard ["applying", "waiting", "recoveryRequired"].contains(last ?? "") else {
        try state(directory, "failed", "İşlem değişiklik başlamadan durdu. Ayrıntılar işlem klasöründeki error.log dosyasında.")
        return
    }
    let recovery: Process
    do { recovery = try launch("--rollback-worker") }
    catch { try state(directory, "recoveryRequired", "Geri alma süreci başlatılamadı: \(error.localizedDescription)"); return }
    if !waitForWorker(recovery, timeout: recoveryTimeout) {
        let stopped = stopWorker(recovery)
        try state(directory, "recoveryRequired", "Geri alma donanım çağrısı zamanında tamamlanmadı. Önceki ayarlara dön seçeneğiyle yeniden deneyin.")
        if !stopped { while recovery.isRunning { Thread.sleep(forTimeInterval: 0.2) } }
    }
    guard status() == "reverted" else {
        try state(directory, "recoveryRequired", "Önceki profilin geri yüklendiği doğrulanamadı; işlem kayıtlarını koruyun.")
        return
    }
}
func runTransaction(_ directory: URL) throws {
    // Runs only under the supervisor, which owns the transaction lock.
    try requireTransactionLock()
    var tx = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: directory.appendingPathComponent("transaction.json")))
    if tx.automatic == true {
        let approved = try readApprovedProfile()
        guard UserDefaults.standard.bool(forKey: "autoProtectWritesEnabled"), approved.uuid == tx.uuid,
              tx.proposed.exactGeometry, tx.proposedOutput?.target == true,
              tx.proposedICC?.activeURL == approved.selection.activeURL else { throw NetError("Otomatik uygulama için etkin kullanıcı onayı yok.") }
        try validatedApprovedICC(approved)
        var expected = tx.preserved ?? [:]
        approved.iccValues.forEach { expected[$0.key] = $0.value }
        guard tx.expectedAfter == expected else { throw NetError("Otomatik korumanın ayar kapsamı geçersiz.") }
    } else if tx.expectedAfter != nil { throw NetError("Elle uygulamada ICC koruma kapsamı değiştirilemez.") }
    let display = try targetDisplay()
    guard identity(display) == tx.uuid, try currentMode(display) == tx.previous else { throw NetError("Ekran işlem hazırlanırken değişti; yazım yapılmadı.") }
    let before = preservationReadback(display)
    guard let preserved = tx.preserved, preserved["iccURL"] != nil,
          preserved["iccContentSHA256"] != nil || preserved["iccSHA256"] != nil,
          preserved["gammaSHA256"] != nil, preserved["gammaSampleCount"] != nil,
          preserved["iccFileContentSHA256"] != nil, preserved["driverDither"] != nil,
          preserved["driverBrightness"] != nil, preserved["fontSmoothing"] != nil,
          preserved.allSatisfy({ before[$0.key] == $0.value }) else {
        throw NetError("ICC/gamma işlem hazırlanırken değişti; ekran ayarı yazılmadı.")
    }
    if let expected = tx.previousColorData {
        guard (ioavLinkReport()["color"] as? [String: Any])?["elementDataBase64"] as? String == expected else {
            throw NetError("HDMI rengi işlem hazırlanırken değişti; yazım yapılmadı.")
        }
    }
    if let expected = tx.previousOutput {
        guard try outputModes(display, mode: tx.previous).current == expected else { throw NetError("Renk seçimi işlem hazırlanırken değişti; yazım yapılmadı.") }
    }
    if let previous = tx.previousICC {
        guard try iccSelection(display) == previous else { throw NetError("ICC seçimi işlem hazırlanırken değişti.") }
    }
    try saveActiveICC(display, to: directory.appendingPathComponent("before.icc"))
    try saveICCFile(display, to: directory.appendingPathComponent("before-file.icc"))
    var needsRollback = true
    defer { if needsRollback { rollback(tx, directory: directory) } }
    try state(directory, "applying", "Ekran modu uygulanıyor.")
    try applyMode(tx.proposed, uuid: tx.uuid, output: tx.proposedOutput)
    if let previous = tx.previousICC, let proposed = tx.proposedICC {
        let current = try iccSelection(targetDisplay())
        try writeJSON(current, to: directory.appendingPathComponent("system-icc-selection.json"))
        guard current.activeURL == previous.activeURL || current.activeURL == proposed.activeURL || current.activeURL == current.factoryURL else {
            throw NetError("ICC seçimi geçiş sırasında dışarıdan değişti.")
        }
        // A system color switch can change the ColorSync mode/profile ID and
        // reset selection. Journal the resolved target before selecting the
        // unchanged original profile for this new system mode.
        let resolved = ICCSelection(profileID: current.profileID, customURL: proposed.customURL,
                                    activeURL: proposed.activeURL, factoryURL: current.factoryURL)
        tx.proposedICC = resolved
        try writeJSON(tx, to: directory.appendingPathComponent("transaction.json"))
        try applyICCSelection(resolved, uuid: tx.uuid, expected: current)
    }
    var settled = false
    var settleError: Error = NetError("ICC/gamma veya video çıkışı geçiş sonrası kararlı değil.")
    for attempt in 0..<12 {
        let id = try targetDisplay()
        let after = preservationReadback(id)
        try writeJSON(after, to: directory.appendingPathComponent("after-preservation.json"))
        try saveActiveICC(id, to: directory.appendingPathComponent("after.icc"))
        try saveICCFile(id, to: directory.appendingPathComponent("after-file.icc"))
        try writeJSON(try currentProfile(id), to: directory.appendingPathComponent("after-profile.json"))
        do {
            try verifyProposedColor(tx, id: id)
            guard preservedValues(tx.expectedAfter ?? tx.preserved ?? [:], match: after, selectedURL: tx.proposedICC?.activeURL) else { throw NetError("ICC/gamma içeriği veya profil seçimi hedef modda farklı.") }
            settled = true; break
        } catch { settleError = error }
        if attempt < 11 { Thread.sleep(forTimeInterval: 0.2) }
    }
    guard settled else { throw settleError }
    try exportDiagnostics(to: directory.appendingPathComponent("after.json"))
    if tx.automatic != true { try state(directory, "waiting", "20 saniye içinde onay verin.") }
    if tx.automatic == true || waitForConfirmation(directory: directory) {
        let id = try targetDisplay()
        guard identity(id) == tx.uuid, try currentMode(id) == tx.proposed, CGDisplayIsInMirrorSet(id) == 0 else { return }
        try verifyProposedColor(tx, id: id)
        let confirmed = preservationReadback(id)
        guard preservedValues(tx.expectedAfter ?? tx.preserved ?? [:], match: confirmed, selectedURL: tx.proposedICC?.activeURL) else { return }
        if tx.automatic != true {
            try writeJSON(tx, to: dataDirectory.appendingPathComponent("previous.json"))
        }
        try state(directory, "kept", tx.proposedOutput?.target == true ? "Tam profil doğrulandı: HiDPI / 100 Hz / 10-bit SDR RGB Tam Aralık." : "Kaydedilen çizim ve renk profili yeniden doğrulandı.")
        needsRollback = false
    }
}

func waitForConfirmation(directory: URL, duration: Double = 20,
                         clock: () -> Double = { ProcessInfo.processInfo.systemUptime },
                         pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }) -> Bool {
    let deadline = clock() + duration
    while clock() < deadline {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel").path) { return false }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("confirm").path) { return true }
        pause()
    }
    return false
}

func exportDiagnostics(to url: URL) throws {
    let info: [String: Any] = ["schemaVersion": 1, "capturedAt": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString, "coreGraphics": cgSnapshot(), "framebuffers": registryDisplays(), "ioavLink": ioavLinkReport(), "transportColorVerification": "See ioavLink.status; successful video read must match a real ColorElement", "betterDisplayDependency": false]
    let data = try JSONSerialization.data(withJSONObject: jsonSafe(info), options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}
