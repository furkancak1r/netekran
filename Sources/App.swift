import AppKit
import ServiceManagement
import ColorSync

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var transaction: URL?
    var child: Process?
    var poll: Timer?
    var alert: NSAlert?
    var message = ""
    var autoProtect = UserDefaults.standard.bool(forKey: "autoProtectWritesEnabled")
    var pendingAutomatic = false
    var lastAutomaticAttempt = -Double.infinity
    var lastOwnedTrial: URL?
    var pendingRemoval = false
    var protectionTimer: Timer?
    var debounce: DispatchWorkItem?
    lazy var monitorBrightness = BrightnessControl(builtIn: false) { [weak self] in self?.transaction == nil }
    lazy var macBrightness = BrightnessControl(builtIn: true) { [weak self] in self?.transaction == nil }


    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try prepareStorage(); if !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("baseline.json").path) { try exportDiagnostics(to: dataDirectory.appendingPathComponent("baseline.json")) } }
        catch { message = error.localizedDescription }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "NetEkran")
        statusItem.button?.toolTip = "NetEkran — görüntü doğrulama"
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; statusItem.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayChanged), name: NSWorkspace.didWakeNotification, object: nil)
        for key in [kColorSyncDeviceProfilesNotification, kColorSyncDisplayDeviceProfilesNotification] {
            if let name = key?.takeUnretainedValue() {
                DistributedNotificationCenter.default().addObserver(self, selector: #selector(displayChanged), name: Notification.Name(name as String), object: nil)
            }
        }
        protectionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.protectIfNeeded() }
        protectionTimer?.tolerance = 5
        let original = dataDirectory.appendingPathComponent("original-profile.json")
        if !FileManager.default.fileExists(atPath: original.path),
           let bytes = try? Data(contentsOf: dataDirectory.appendingPathComponent("previous.json")),
           let previous = try? JSONDecoder().decode(Transaction.self, from: bytes),
           previous.proposedICC?.activeURL.contains("/NetEkran/preserved-icc-") == true {
            try? bytes.write(to: original, options: .atomic)
        }
        rebuild()
        if autoProtect { displayChanged() }
        if CommandLine.arguments.contains("--trial") { DispatchQueue.main.async { self.apply() } }
        if CommandLine.arguments.contains("--system-trial") { DispatchQueue.main.async { self.systemTrial() } }
        if CommandLine.arguments.contains("--restore-trial") { DispatchQueue.main.async { self.restore() } }
    }
    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        monitorBrightness.refresh()
        macBrightness.refresh()
    }
    @discardableResult func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled
        statusItem.menu?.addItem(item); return item
    }
    func rebuild() {
        statusItem.menu?.removeAllItems()
        add("NetEkran · GB-2411FF", enabled: false)
        add("Hedef: 1920×1080 HiDPI · 100 Hz", enabled: false)
        add("Hedef renk: 10-bit · SDR · RGB · Tam Aralık", enabled: false)
        do {
            let id = try targetDisplay(), p = try currentProfile(id), a = assessTarget(p)
            add("Bağlı\(CGDisplayIsAsleep(id) != 0 ? " · uykuda" : "") · kimlik: \(p.identity.prefix(8))", enabled: false)
            add("Okunan: \(p.logicalWidth)×\(p.logicalHeight) · çizim \(p.pixelWidth)×\(p.pixelHeight) · \(p.refreshHz) Hz", enabled: false)
            add(p.mirrored ? "Yansıtma açık — uygulama engellendi" : "Yansıtma kapalı", enabled: false)
            if !a.matchesTarget { add(a.resolutionVerified && a.refreshVerified && !p.mirrored ? "Kısmi: çizim hedefi doğrulandı" : "Çizim hedefi eşleşmiyor", enabled: false) }
            let color = p.bitDepth.map { "\($0)-bit · \(p.hdr == false ? "SDR" : "HDR") · \(p.encoding ?? "?") · \(p.fullRange == true ? "Tam Aralık" : "Sınırlı Aralık")" } ?? "doğrulanamadı"
            add("Okunan video çıkışı: " + color, enabled: false)
            if a.matchesTarget { add("Tam hedef doğrulandı", enabled: false) }
        } catch { add(error.localizedDescription, enabled: false) }
        if !message.isEmpty { add(message, enabled: false) }
        statusItem.menu?.addItem(.separator())
        monitorBrightness.add(to: statusItem.menu!)
        macBrightness.add(to: statusItem.menu!)
        statusItem.menu?.addItem(.separator())
        add("Net görüntüyü uygula…", #selector(apply), enabled: transaction == nil)
        add("Tek HiDPI kaydını yeniden oluştur…", #selector(provision), enabled: transaction == nil)
        let protect = add("Ayarları otomatik koru", #selector(toggleProtect), enabled: transaction == nil); protect.state = autoProtect ? .on : .off
        let login = add("Oturum açılışında başlat", #selector(toggleLogin)); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add("Önceki ayarlara dön…", #selector(restore), enabled: transaction == nil)
        add("Uygulamanın yaptığı değişiklikleri kaldır…", #selector(uninstallChanges), enabled: transaction == nil)
        add("Tanılama raporunu dışa aktar…", #selector(export))
        add("Çıkış", #selector(quit))
    }
    func notice(_ text: String) {
        let a = NSAlert(); a.messageText = "NetEkran"; a.informativeText = text; a.addButton(withTitle: "Tamam")
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
    @objc func apply() {
        do {
            let id = try targetDisplay()
            guard CGDisplayIsAsleep(id) == 0 else { throw NetError("Önce hedef ekranı uyandırın.") }
            if assessTarget(try currentProfile(id)).matchesTarget {
                try recordApprovedProfile(id)
                message = "Tam hedef zaten uygulanmış; ekran ayarı değiştirilmedi."; rebuild(); return
            }
            systemTrial()
        } catch { notice(error.localizedDescription) }
    }
    func systemTrial() {
        do {
            let id = try targetDisplay()
            guard let mode = modes(id).map(ModeRecord.init).first(where: { $0.exactGeometry }) else { throw NetError("Tam HiDPI / 100 Hz modu bulunamadı.") }
            let candidates = try outputModes(id, mode: mode).options.filter(\.target)
            guard candidates.count == 1, let output = candidates.first else { throw NetError("Tek bir 10-bit SDR RGB Tam Aralık çıkışı yok.") }
            try start(mode, output: output)
        } catch { notice(error.localizedDescription) }
    }
    func start(_ proposed: ModeRecord, output: OutputRecord? = nil, expectedColor: String? = nil, selectedICC: ICCSelection? = nil, automatic: Bool = false) throws {
        guard transaction == nil else { throw NetError("Bir işlem zaten sürüyor.") }
        let id = try targetDisplay(); guard let uuid = identity(id) else { throw NetError("Kalıcı ekran kimliği okunamadı.") }
        try prepareStorage()
        let dir = dataDirectory.appendingPathComponent("transaction-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try exportDiagnostics(to: dir.appendingPathComponent("before.json"))
        let previous = try currentMode(id)
        let previousOutput = try outputModes(id, mode: previous).current
        let link = ioavLinkReport()["color"] as? [String: Any]
        guard let previousColor = link?["elementDataBase64"] as? String, previousOutput != nil else { throw NetError("Geri dönüş için mevcut renk çıkışı okunamadı; ayar değiştirilmedi.") }
        let beforeICC = try iccSelection(id)
        let afterICC = try selectedICC ?? (output?.target == true ? preservedICCSelection(beforeICC) : beforeICC)
        let beforeValues = preservationForTransaction(id)
        var expectedAfter: [String: String]?
        if automatic {
            let approved = try readApprovedProfile(); try validatedApprovedICC(approved)
            var expected = beforeValues; approved.iccValues.forEach { expected[$0.key] = $0.value }; expectedAfter = expected
        }
        try writeJSON(Transaction(uuid: uuid, previous: previous, proposed: proposed, preserved: beforeValues, previousOutput: previousOutput, proposedOutput: output, previousColorData: previousColor, proposedColorData: expectedColor, previousICC: beforeICC, proposedICC: afterICC, automatic: automatic, expectedAfter: expectedAfter), to: dir.appendingPathComponent("transaction.json"))
        let original = dataDirectory.appendingPathComponent("original-profile.json")
        if output?.target == true && !FileManager.default.fileExists(atPath: original.path) {
            try Data(contentsOf: dir.appendingPathComponent("transaction.json")).write(to: original, options: .atomic)
        }
        let process = Process(); process.executableURL = Bundle.main.executableURL; process.arguments = ["--watchdog", dir.path]
        let errorURL = dir.appendingPathComponent("error.log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL); defer { try? errorHandle.close() }
        process.standardError = errorHandle
        try process.run(); child = process; transaction = dir; pendingAutomatic = automatic; lastOwnedTrial = dir
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.readTransaction() }
    }
    func readTransaction() {
        guard let dir = transaction else { return }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("state.json")), let state = try? JSONDecoder().decode(TransactionState.self, from: data) else {
            if child?.isRunning == false { finish("Koruyucu süreç başlatılamadı; tanılama kaydını inceleyin.") }; return
        }
        if state.status == "waiting", alert == nil {
            let a = NSAlert(); a.messageText = "Bu ayarları koru?"; a.informativeText = "20 saniye içinde onay verilmezse önceki çizim moduna dönülür. Uygulama, gerçek çizim ve renk çıkışını yeniden okur."
            a.addButton(withTitle: "Bu ayarları koru"); a.addButton(withTitle: "Geri dön")
            alert = a; NSApp.activate(ignoringOtherApps: true)
            a.beginSheetModal(for: confirmationWindow()) { response in
                try? Data().write(to: dir.appendingPathComponent(response == .alertFirstButtonReturn ? "confirm" : "cancel"), options: .atomic)
            }
        } else if ["kept", "reverted", "recoveryRequired", "failed"].contains(state.status) { finish(state.message, succeeded: state.status == "kept") }
        else if child?.isRunning == false { finish("Koruyucu süreç beklenmedik biçimde durdu. Önceki ayarlara dön seçeneğini kullanın.") }
    }
    var confirmWindow: NSWindow?
    func confirmationWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 420,height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "NetEkran · güvenli uygulama"; w.center(); w.makeKeyAndOrderFront(nil); confirmWindow = w; return w
    }
    func finish(_ text: String, succeeded: Bool = false) {
        if pendingAutomatic && !succeeded { autoProtect = false; UserDefaults.standard.set(false, forKey: "autoProtectWritesEnabled") }
        pendingAutomatic = false
        let removeAfterward = pendingRemoval && succeeded; pendingRemoval = false
        poll?.invalidate(); poll = nil
        if let a = alert, let w = confirmWindow, w.attachedSheet === a.window { w.endSheet(a.window, returnCode: .abort) }
        confirmWindow?.orderOut(nil); confirmWindow = nil; alert = nil; transaction = nil; child = nil; message = text; rebuild()
        if removeAfterward { elevated("--remove-override") }
    }
    @objc func restore() {
        autoProtect = false; UserDefaults.standard.set(false, forKey: "autoProtectWritesEnabled")
        do {
            let tx = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: dataDirectory.appendingPathComponent("previous.json")))
            guard identity(try targetDisplay()) == tx.uuid else { throw NetError("Geri dönüş kaydı bu ekrana ait değil.") }
            try start(tx.previous, output: tx.previousOutput, expectedColor: tx.previousColorData, selectedICC: tx.previousICC)
        } catch { notice("Geri dönüş başlatılamadı: \(error.localizedDescription)") }
    }
    func elevated(_ argument: String) {
        guard let executable = Bundle.main.executableURL?.path else { return }
        let command = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' " + argument
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let output = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        notice(error.map { String(describing: $0[NSAppleScript.errorMessage] ?? $0) } ?? output?.stringValue ?? "İşlem sonucu okunamadı.")
    }
    @objc func provision() { elevated("--install-override") }
    @objc func uninstallChanges() {
        autoProtect = false; UserDefaults.standard.set(false, forKey: "autoProtectWritesEnabled")
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            let id = try targetDisplay(), current = try iccSelection(id)
            if current.activeURL.contains("/NetEkran/preserved-icc-") {
                guard assessTarget(try currentProfile(id)).matchesTarget else { throw NetError("Çıkış sonradan değişmiş; başka ayarların üzerine yazmadan önceki profil kaydını inceleyin.") }
                let saved = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: dataDirectory.appendingPathComponent("original-profile.json")))
                guard saved.uuid == identity(id), saved.previousICC != nil else { throw NetError("Bu ekranın özgün ICC geri dönüş kaydı yok.") }
                try start(saved.previous, output: saved.previousOutput, expectedColor: saved.previousColorData, selectedICC: saved.previousICC)
                pendingRemoval = true
            } else { elevated("--remove-override") }
        } catch { notice(error.localizedDescription) }
    }
    @objc func toggleProtect() {
        do {
            if !autoProtect { try recordApprovedProfile(targetDisplay()) }
            autoProtect.toggle(); UserDefaults.standard.set(autoProtect, forKey: "autoProtectWritesEnabled")
            message = autoProtect ? "Otomatik koruma açık: onaylanan profil, ekran bağlanınca ve uyanınca korunur." : "Otomatik koruma kapalı."
            rebuild(); if autoProtect { displayChanged() }
        } catch { notice(error.localizedDescription) }
    }
    func protectIfNeeded() {
        guard autoProtect, transaction == nil, ProcessInfo.processInfo.systemUptime - lastAutomaticAttempt >= 30 else { return }
        do {
            let id = try targetDisplay()
            guard CGDisplayIsAsleep(id) == 0 else { return }
            let approved = try readApprovedProfile()
            let profile = try currentProfile(id), selection = try iccSelection(id)
            guard try automaticRecoveryNeeded(profile, selection: selection, approved: approved, preserved: preservationReadback(id)) else { return }
            try validatedApprovedICC(approved)
            guard let mode = modes(id).map(ModeRecord.init).first(where: { $0.exactGeometry }) else { throw NetError("Onaylanan tam HiDPI/100 Hz modu artık sunulmuyor.") }
            let outputs = try outputModes(id, mode: mode).options.filter(\.target)
            guard outputs.count == 1, let output = outputs.first else { throw NetError("Tam RGB renk modu sunulmuyor.") }
            lastAutomaticAttempt = ProcessInfo.processInfo.systemUptime
            try start(mode, output: output, selectedICC: approved.selection, automatic: true)
        } catch { message = "Otomatik koruma: " + error.localizedDescription }
    }
    @objc func displayChanged() {
        debounce?.cancel(); let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.protectIfNeeded(); self.rebuild()
        }; debounce = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    @objc func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { notice("Oturum açılışı için Sistem Ayarları → Genel → Giriş Öğeleri bölümünde NetEkran'a izin verin.") }
        } catch { notice(error.localizedDescription) }; rebuild()
    }
    @objc func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "NetEkran-tanilama.json"
        if panel.runModal() == .OK, let url = panel.url { do { try exportDiagnostics(to: url) } catch { notice(error.localizedDescription) } }
    }
    @objc func quit() { if let dir = transaction { try? Data().write(to: dir.appendingPathComponent("cancel")) }; NSApp.terminate(nil) }
}

@main struct NetEkran {
    static func main() {
        let args = CommandLine.arguments
        do {
            if args == [args[0], "--builtin-brightness-read"] || (args.count == 3 && ["--builtin-brightness-set", "--builtin-auto-brightness"].contains(args[1])) {
                var percent: Double?, automatic: Bool?
                if args.count == 3 {
                    if args[1] == "--builtin-auto-brightness" {
                        guard ["on", "off"].contains(args[2]) else { throw NetError("Otomatik parlaklık için on/off seçin.") }
                        automatic = args[2] == "on"
                    } else {
                        guard let value = Double(args[2]) else { throw NetError("Geçersiz parlaklık yüzdesi.") }
                        percent = value
                    }
                }
                print(String(data: try JSONEncoder().encode(builtInBrightnessRequest(percent: percent, automatic: automatic)), encoding: .utf8)!)
                return
            }
            if args == [args[0], "--brightness-read"] || (args.count == 3 && args[1] == "--brightness-set") {
                var percent: Double?
                if args.count == 3 {
                    guard let value = Double(args[2]) else { throw NetError("Geçersiz parlaklık yüzdesi.") }
                    percent = value
                }
                print(String(data: try JSONEncoder().encode(brightnessRequest(percent: percent)), encoding: .utf8)!)
                return
            }
            if args.count == 3 && args[1] == "--diagnose" { try exportDiagnostics(to: URL(fileURLWithPath: args[2])); return }
            if args.count == 3 && args[1] == "--watchdog" { try runWatchdog(URL(fileURLWithPath: args[2])); return }
            if args.count == 3 && args[1] == "--transaction-worker" { try runTransaction(URL(fileURLWithPath: args[2])); return }
            if args.count == 3 && args[1] == "--rollback-worker" {
                try requireTransactionLock()
                let dir = URL(fileURLWithPath: args[2])
                let tx = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: dir.appendingPathComponent("transaction.json")))
                rollback(tx, directory: dir); return
            }
            if args.count == 2 && args[1] == "--install-override" { print(try modifyOverride(remove: false)); return }
            if args.count == 2 && args[1] == "--remove-override" { print(try modifyOverride(remove: true)); return }
            guard args.count == 1 || args == [args[0], "--trial"] || args == [args[0], "--system-trial"] || args == [args[0], "--restore-trial"] else { throw NetError("Geçersiz komut.") }
            let app = NSApplication.shared, delegate = AppDelegate(); app.setActivationPolicy(.accessory); app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
}
