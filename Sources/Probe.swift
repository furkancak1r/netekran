import Foundation
import CoreGraphics
import IOKit
import ColorSync
import CryptoKit

func registryDisplays() -> [[String: Any]] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [[String: Any]] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { continue }
        var path = [CChar](repeating: 0, count: 4096)
        IORegistryEntryGetPath(service, kIOServicePlane, &path)
        var selected: [String: Any] = ["registryPath": String(cString: path)]
        for (key, value) in dict where ["DisplayAttributes", "DisplayWidth", "DisplayHeight", "ColorElements", "TimingElements", "EDID UUID", "enableDither", "Transport", "IOMFBUUID", "IOMFBBrightnessLevel"].contains(key) || key.lowercased().contains("current") || key.lowercased().contains("edid") || key.lowercased().contains("modeid") {
            selected[key] = value
        }
        selected["availablePropertyKeys"] = dict.keys.sorted()
        result.append(selected)
    }
    return result
}
func jsonSafe(_ value: Any) -> Any {
    if let data = value as? Data { return data.base64EncodedString() }
    if let d = value as? [String: Any] { return d.mapValues(jsonSafe) }
    if let a = value as? [Any] { return a.map(jsonSafe) }
    if let url = value as? URL { return url.absoluteString }
    if let d = value as? Date { return ISO8601DateFormatter().string(from: d) }
    return value
}
func cgSnapshot() -> [[String: Any]] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    let err = CGGetOnlineDisplayList(32, &ids, &count)
    guard err == .success else { return [["error": err.rawValue]] }
    return ids.prefix(Int(count)).map { id in
        var r: [String: Any] = ["id": id, "vendor": CGDisplayVendorNumber(id), "product": CGDisplayModelNumber(id), "serial": CGDisplaySerialNumber(id), "builtIn": CGDisplayIsBuiltin(id) != 0, "mirrored": CGDisplayIsInMirrorSet(id) != 0, "asleep": CGDisplayIsAsleep(id) != 0]
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() { r["uuid"] = CFUUIDCreateString(nil, uuid) as String }
        func mode(_ m: CGDisplayMode) -> [String: Any] { ["id": m.ioDisplayModeID, "logicalWidth": m.width, "logicalHeight": m.height, "pixelWidth": m.pixelWidth, "pixelHeight": m.pixelHeight, "refreshHz": m.refreshRate, "flags": m.ioFlags] }
        r["preservationReadback"] = preservationReadback(id)
        if let m = CGDisplayCopyDisplayMode(id) { r["current"] = mode(m) }
        r["modes"] = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []).map(mode)
        return r
    }
}


// Fingerprints are readback evidence only. Never assign ICC/gamma to force a match.
func preservationReadback(_ id: CGDirectDisplayID) -> [String: String] {
    var result: [String: String] = [:]
    let drivers = registryDisplays().filter {
        let product = ($0["DisplayAttributes"] as? [String: Any])?["ProductAttributes"] as? [String: Any]
        return product?["LegacyManufacturerID"] as? UInt32 == CGDisplayVendorNumber(id) && product?["ProductID"] as? UInt32 == CGDisplayModelNumber(id)
    }
    if drivers.count == 1 {
        if let value = drivers[0]["enableDither"] { result["driverDither"] = String(describing: value) }
        if let value = drivers[0]["IOMFBBrightnessLevel"] { result["driverBrightness"] = String(describing: value) }
    }
    result["fontSmoothing"] = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleFontSmoothing"].map { String(describing: $0) } ?? "<unset>"
    if let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue() {
        var error: Unmanaged<CFError>?
        if let data = ColorSyncProfileCopyData(profile, &error)?.takeRetainedValue() {
            let raw = data as Data
            result["iccSHA256"] = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
            if let canonical = iccWithoutCreationTime(raw) {
                result["iccContentSHA256"] = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            }
            if let url = ColorSyncProfileGetURL(profile, nil)?.takeUnretainedValue() {
                result["iccURL"] = (url as URL).absoluteString
                if let bytes = try? Data(contentsOf: url as URL) {
                    result["iccFileSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    result["iccFileSize"] = String(bytes.count)
                    if let normalized = iccWithoutCreationTime(bytes) {
                        result["iccFileContentSHA256"] = SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
                    }
                }
            }
        }
        _ = error?.takeRetainedValue()
    }
    let capacity = CGDisplayGammaTableCapacity(id)
    guard capacity > 0, capacity <= 65536 else { return result }
    var red = [CGGammaValue](repeating: 0, count: Int(capacity)), green = red, blue = red
    var count: UInt32 = 0
    guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success,
          count > 0, count <= capacity else { return result }
    var data = Data()
    for channel in [red, green, blue] {
        data.append(channel.withUnsafeBytes { Data($0.prefix(Int(count) * MemoryLayout<CGGammaValue>.size)) })
    }
    result["gammaSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    result["gammaSampleCount"] = String(count)
    return result
}

func iccWithoutCreationTime(_ data: Data) -> Data? {
    guard data.count >= 128, String(data: data[36..<40], encoding: .ascii) == "acsp" else { return nil }
    var normalized = data
    // macOS regenerates its monitor ICC on a link switch. Only the creation date
    // is ignored; every color tag, remaining header byte and profile URL is checked.
    normalized.replaceSubrange(24..<36, with: repeatElement(UInt8(0), count: 12))
    return normalized
}
func preservationForTransaction(_ id: CGDirectDisplayID) -> [String: String] {
    let readback = preservationReadback(id)
    // Keep the raw hash if semantic normalization was unavailable.
    return readback.filter {
        ($0.key != "iccSHA256" || readback["iccContentSHA256"] == nil) &&
        ($0.key != "iccFileSHA256" || readback["iccFileContentSHA256"] == nil)
    }
}

func saveActiveICC(_ id: CGDirectDisplayID, to url: URL) throws {
    guard let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue(),
          let data = ColorSyncProfileCopyData(profile, nil)?.takeRetainedValue() else { throw NSError(domain: "NetEkran", code: 1, userInfo: [NSLocalizedDescriptionKey: "Aktif ICC verisi yedeklenemedi."]) }
    try (data as Data).write(to: url, options: .atomic)
}
func saveICCFile(_ id: CGDirectDisplayID, to url: URL) throws {
    guard let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue(),
          let source = ColorSyncProfileGetURL(profile, nil)?.takeUnretainedValue() else { throw NetError("Seçili ICC dosyası bulunamadı.") }
    let bytes = try Data(contentsOf: source as URL)
    try bytes.write(to: url, options: .atomic)
}
