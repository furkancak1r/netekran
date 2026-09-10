import Foundation
import CoreGraphics
import ColorSync
import CryptoKit

struct ICCSelection: Codable, Equatable {
    let profileID: String
    let customURL: String?
    let activeURL: String
    let factoryURL: String?
}
struct ApprovedProfile: Codable {
    let uuid: String
    let selection: ICCSelection
    let iccValues: [String: String]
}
let approvedProfileURL = dataDirectory.appendingPathComponent("approved-profile.json")
func readApprovedProfile() throws -> ApprovedProfile {
    try JSONDecoder().decode(ApprovedProfile.self, from: Data(contentsOf: approvedProfileURL))
}
func recordApprovedProfile(_ id: CGDirectDisplayID) throws {
    guard assessTarget(try currentProfile(id)).matchesTarget, let uuid = identity(id) else { throw NetError("Otomatik koruma için tam hedef önce doğrulanmalı.") }
    let selection = try preservedICCSelection(iccSelection(id))
    var values = preservationForTransaction(id).filter { $0.key.hasPrefix("icc") }
    values["iccURL"] = selection.activeURL
    try writeJSON(ApprovedProfile(uuid: uuid, selection: selection, iccValues: values), to: approvedProfileURL)
}
func automaticRecoveryNeeded(_ profile: DisplayProfile, selection: ICCSelection, approved: ApprovedProfile, preserved: [String: String]) throws -> Bool {
    guard profile.identity == approved.uuid, !profile.mirrored else { throw NetError("Otomatik koruma: ekran kimliği veya yansıtma durumu değişti.") }
    guard selection.activeURL == approved.selection.activeURL || selection.activeURL == selection.factoryURL else { throw NetError("ICC profili dışarıdan değiştirilmiş; otomatik koruma durduruldu.") }
    return !assessTarget(profile).matchesTarget || !preservedValues(approved.iccValues, match: preserved)
}
func validatedApprovedICC(_ approved: ApprovedProfile) throws {
    guard let file = URL(string: approved.selection.activeURL), file.isFileURL,
          let normalized = iccWithoutCreationTime(try Data(contentsOf: file)),
          SHA256.hash(data: normalized).map({ String(format: "%02x", $0) }).joined() == approved.iccValues["iccFileContentSHA256"] else {
        throw NetError("Onaylanan ICC dosyasının içeriği değişmiş; otomatik uygulama yapılmadı.")
    }
}
private func cs(_ value: Unmanaged<CFString>?) -> CFString { value!.takeUnretainedValue() }
func iccSelection(_ id: CGDirectDisplayID) throws -> ICCSelection {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
          let info = ColorSyncDeviceCopyDeviceInfo(cs(kColorSyncDisplayDeviceClass), uuid)?.takeRetainedValue() as? [String: Any],
          let factory = info[cs(kColorSyncFactoryProfiles) as String] as? [String: Any],
          let profileID = factory[cs(kColorSyncDeviceDefaultProfileID) as String] as? String,
          let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue(),
          let active = ColorSyncProfileGetURL(profile, nil)?.takeUnretainedValue() else { throw NetError("ICC seçimi güvenilir biçimde okunamadı.") }
    let custom = info[cs(kColorSyncCustomProfiles) as String] as? [String: Any] ?? [:]
    let item = factory[profileID] as? [String: Any]
    let customURL = custom[profileID] as? URL
    if let value = custom[profileID], !(value is NSNull), customURL == nil { throw NetError("ICC özel profil URL türü bilinmiyor.") }
    return ICCSelection(profileID: profileID, customURL: customURL?.absoluteString,
                        activeURL: (active as URL).absoluteString,
                        factoryURL: (item?[cs(kColorSyncDeviceProfileURL) as String] as? URL)?.absoluteString)
}
func preservedICCSelection(_ before: ICCSelection, storage: URL = dataDirectory) throws -> ICCSelection {
    // Only the auto-generated factory file needs a stable copy. Custom ICC
    // files keep their existing selection and are checked by the same guard.
    guard let factory = before.factoryURL else { throw NetError("Fabrika ICC kaynağı doğrulanamadı.") }
    guard before.activeURL == factory else { return before }
    guard let source = URL(string: before.activeURL), source.isFileURL else { throw NetError("ICC kaynağı yerel dosya değil.") }
    let bytes = try Data(contentsOf: source)
    guard iccWithoutCreationTime(bytes) != nil else { throw NetError("ICC kaynağı geçersiz.") }
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let copy = storage.appendingPathComponent("preserved-icc-\(hash).icc")
    if FileManager.default.fileExists(atPath: copy.path) {
        guard try Data(contentsOf: copy) == bytes else { throw NetError("Korunan ICC kopyası değişmiş.") }
    } else { try bytes.write(to: copy, options: .atomic) }
    return ICCSelection(profileID: before.profileID, customURL: copy.absoluteString, activeURL: copy.absoluteString, factoryURL: before.factoryURL)
}
func applyICCSelection(_ selection: ICCSelection, uuid: String, expected: ICCSelection) throws {
    let id = try targetDisplay()
    guard identity(id) == uuid else { throw NetError("ICC işleminde ekran kimliği değişti.") }
    let current = try iccSelection(id)
    if current == selection { return }
    guard current == expected, current.profileID == selection.profileID,
          let device = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { throw NetError("ICC seçimi başka bir işlem tarafından değiştirildi.") }
    let value: Any
    if let string = selection.customURL {
        guard let url = URL(string: string), url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw NetError("Kaydedilen ICC dosyası okunamıyor.") }
        value = url
    } else { value = NSNull() }
    let info: [String: Any] = [selection.profileID: value,
                              cs(kColorSyncProfileUserScope) as String: kCFPreferencesCurrentUser as Any,
                              cs(kColorSyncProfileHostScope) as String: kCFPreferencesCurrentHost as Any]
    guard ColorSyncDeviceSetCustomProfiles(cs(kColorSyncDisplayDeviceClass), device, info as CFDictionary) else { throw NetError("Özgün ICC profilinin seçimi sistem tarafından reddedildi.") }
    for _ in 0..<10 {
        if try iccSelection(id).activeURL == selection.activeURL { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw NetError("ICC seçimi yeniden doğrulanamadı.")
}
func preservedValues(_ expected: [String: String], match actual: [String: String], selectedURL: String? = nil) -> Bool {
    expected.allSatisfy { key, value in actual[key] == (key == "iccURL" ? selectedURL ?? value : value) }
}
