import Foundation
import CryptoKit

let exactScaleEntry = Data([0,0,15,0,0,0,8,112,0,0,0,9,0,32,0,0])
let overrideURL = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-3481/DisplayProductID-238")
let overrideJournal = URL(fileURLWithPath: "/Library/Application Support/NetEkran")
func mergeTargetOverride(_ existing: [String: Any]?) throws -> (dictionary: [String: Any], added: Bool) {
    var dict = existing ?? ["DisplayVendorID": 13441, "DisplayProductID": 568]
    guard dict["DisplayVendorID"] as? Int == 13441, dict["DisplayProductID"] as? Int == 568 else { throw NetError("Ekran yapılandırma kimliği uyuşmuyor.") }
    guard dict["scale-resolutions"] == nil || dict["scale-resolutions"] is [Data] else { throw NetError("scale-resolutions biçimi tanınmıyor; dosya değiştirilmedi.") }
    var entries = dict["scale-resolutions"] as? [Data] ?? []
    if entries.contains(exactScaleEntry) { return (dict, false) }
    entries.append(exactScaleEntry); dict["scale-resolutions"] = entries
    return (dict, true)
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func noSymlinkComponents(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/")
    for component in url.pathComponents.dropFirst() {
        current.appendPathComponent(component)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw NetError("Sembolik bağlantı nedeniyle güvenli yazma reddedildi: \(current.path)") }
    }
}
struct OverrideReceipt: Codable {
    let original: Data?
    let installedSHA256: String
}
// ponytail: injectable single-entry filesystem core; production wrapper keeps fixed paths + root + full symlink walk + journal ownership, core keeps lock + exact entry + foreign-data refusal so temp-dir tests stay faithful. Ceiling: core checks only injected leaves for symlinks; fixed-path full walk stays in modifyOverride.
func scopedNoSymlinkLeaf(_ url: URL) throws {
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw NetError("Sembolik bağlantı nedeniyle güvenli yazma reddedildi: \(url.path)") }
}
func withOverrideLock(journalURL: URL, _ body: () throws -> String) throws -> String {
    try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try scopedNoSymlinkLeaf(journalURL)
    let lock = open(journalURL.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw NetError("Yapılandırma kilidi açılamadı.") }; defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NetError("Başka bir yapılandırma işlemi sürüyor.") }
    return try body()
}
func installOverrideEntry(targetURL: URL, journalURL: URL) throws -> String {
    try scopedNoSymlinkLeaf(targetURL.deletingLastPathComponent())
    try scopedNoSymlinkLeaf(targetURL)
    return try withOverrideLock(journalURL: journalURL) {
        let receiptURL = journalURL.appendingPathComponent("receipt.json")
        let original = FileManager.default.fileExists(atPath: targetURL.path) ? try Data(contentsOf: targetURL) : nil
        let parsed = try original.map { try PropertyListSerialization.propertyList(from: $0, format: nil) }
        guard parsed == nil || parsed is [String: Any] else { throw NetError("Ekran yapılandırması sözlük değil.") }
        let merged = try mergeTargetOverride(parsed as? [String: Any])
        guard merged.added else { return "Tam 1920×1080 HiDPI kaydı zaten var; sistem dosyası değiştirilmedi." }
        let data = try PropertyListSerialization.data(fromPropertyList: merged.dictionary, format: .xml, options: 0)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            // ponytail: stale write-ahead receipt where target still equals original means crash before atomic write; same desired bytes resume safely, anything else fails closed to protect the recorded backup.
            let receipt = try JSONDecoder().decode(OverrideReceipt.self, from: Data(contentsOf: receiptURL))
            guard original == receipt.original && digest(data) == receipt.installedSHA256 else { throw NetError("Önceki NetEkran değişikliği kayıtlı; yedeğin üzerine yazılmadı.") }
        } else {
            // Write-ahead receipt retains original bytes before the single-display atomic write.
            try writeJSON(OverrideReceipt(original: original, installedSHA256: digest(data)), to: receiptURL)
        }
        guard (try? Data(contentsOf: targetURL)) == original else { throw NetError("Yapılandırma eşzamanlı değişti; işlem durduruldu.") }
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: targetURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: targetURL.path)
        return "Tek HiDPI kaydı oluşturuldu. Etkin mod ve renk ayarları değişmedi. macOS'un kaydı yüklemesi için ekranı yeniden bağlamak veya daha sonra yeniden başlatmak gerekebilir; bu otomatik yapılmayacak."
    }
}
func removeOverrideEntry(targetURL: URL, journalURL: URL) throws -> String {
    try scopedNoSymlinkLeaf(targetURL.deletingLastPathComponent())
    try scopedNoSymlinkLeaf(targetURL)
    return try withOverrideLock(journalURL: journalURL) {
        let receiptURL = journalURL.appendingPathComponent("receipt.json")
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return "NetEkran'ın kaldırılacak sistem değişikliği yok." }
        let receipt = try JSONDecoder().decode(OverrideReceipt.self, from: Data(contentsOf: receiptURL))
        let original = FileManager.default.fileExists(atPath: targetURL.path) ? try Data(contentsOf: targetURL) : nil
        if original == receipt.original {
            try FileManager.default.removeItem(at: receiptURL)
            return "Yapılandırma zaten önceki durumda; tamamlanmamış işlem kaydı temizlendi."
        }
        guard let current = original, digest(current) == receipt.installedSHA256 else { throw NetError("Dosya sonradan değişmiş; başka ayarları korumak için kaldırma durduruldu. Yedek: \(journalURL.path)") }
        if let backup = receipt.original { try backup.write(to: targetURL, options: .atomic) }
        else { try FileManager.default.removeItem(at: targetURL) }
        try FileManager.default.removeItem(at: receiptURL)
        return "Yalnız NetEkran'ın yaptığı yapılandırma değişikliği kaldırıldı. Etkin moda dokunulmadı; yeniden bağlama veya yeniden başlatma gerekebilir."
    }
}
func modifyOverride(remove: Bool) throws -> String {
    guard geteuid() == 0 else { throw NetError("Bu işlem için macOS yönetici izni gerekir.") }
    try noSymlinkComponents(overrideURL); try noSymlinkComponents(overrideJournal)
    try FileManager.default.createDirectory(at: overrideJournal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let journalAttributes = try FileManager.default.attributesOfItem(atPath: overrideJournal.path)
    guard (journalAttributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
          ((journalAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else {
        throw NetError("Yönetici yedek klasörünün sahipliği veya izinleri güvenli değil.")
    }
    if remove { return try removeOverrideEntry(targetURL: overrideURL, journalURL: overrideJournal) }
    return try installOverrideEntry(targetURL: overrideURL, journalURL: overrideJournal)
}
