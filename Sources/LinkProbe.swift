import Foundation
import IOKit

// Read-only private IOAV ABI inspected on macOS 26.6.2/25G83. Keep raw
// bytes as evidence and require an exact match with the driver ColorElements.
func ioavLinkReport() -> [String: Any] {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    guard version.majorVersion == 26 && version.minorVersion == 6 && version.patchVersion == 2 else {
        return ["status": "unsupportedOS", "reason": "Private IOAV ABI only inspected on macOS 26.6.2"]
    }
    guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return ["status": "unavailable"] }
    defer { dlclose(h) }
    guard let createSymbol = dlsym(h, "IOAVServiceCreateWithService"), let edidSymbol = dlsym(h, "IOAVServiceCopyEDID"), let linkSymbol = dlsym(h, "IOAVServiceGetLinkData") else { return ["status": "missingSymbols"] }
    typealias Create = @convention(c) (CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    typealias EDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32
    typealias Link = @convention(c) (CFTypeRef, UInt32, UnsafeMutableRawPointer) -> Int32
    let create = unsafeBitCast(createSymbol, to: Create.self)
    let readEDID = unsafeBitCast(edidSymbol, to: EDID.self)
    let readLink = unsafeBitCast(linkSymbol, to: Link.self)
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return ["status": "serviceUnavailable"] }
    defer { IOObjectRelease(iterator) }
    var candidates: [(CFTypeRef, Data)] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        guard let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
        var data: Unmanaged<CFData>?
        let result = readEDID(service, &data)
        let edid = data?.takeRetainedValue() as Data?
        guard result == 0, let bytes = edid, validTargetEDID(bytes) else { continue }
        candidates.append((service, bytes))
    }
    guard candidates.count == 1 else { return ["status": "unmatchedOrAmbiguous", "matchingServices": candidates.count] }
    var bytes = [UInt8](repeating: 0, count: 272)
    let result = bytes.withUnsafeMutableBytes { readLink(candidates[0].0, 1, $0.baseAddress!) }
    var report: [String: Any] = ["status": result == 0 ? "rawLinkReadNeedsValidation" : (result == kIOReturnOffline ? "offline" : "readFailed"), "ioReturn": result, "edidBase64": candidates[0].1.base64EncodedString(), "transportColorVerified": false]
    if result == 0 {
        report["rawLinkBase64"] = Data(bytes).base64EncodedString()
        let targets = registryDisplays().filter {
            let attrs = $0["DisplayAttributes"] as? [String: Any]
            let product = attrs?["ProductAttributes"] as? [String: Any]
            return product?["LegacyManufacturerID"] as? Int == Int(targetVendor) && product?["ProductID"] as? Int == Int(targetProduct)
        }
        if targets.count == 1, let elements = targets[0]["ColorElements"] as? [[String: Any]],
           let color = decodeVideoColor(Data(bytes), elements: elements) {
            report["status"] = "videoColorVerified"
            report["transportColorVerified"] = true
            report["color"] = color
        }
    }
    return report
}
func validTargetEDID(_ bytes: Data) -> Bool {
    guard bytes.count >= 128, bytes.count <= 4096, bytes.count % 128 == 0,
          Array(bytes.prefix(8)) == [0,255,255,255,255,255,255,0],
          bytes.count == (Int(bytes[126]) + 1) * 128,
          UInt32(bytes[8]) * 256 + UInt32(bytes[9]) == targetVendor,
          UInt32(bytes[10]) + UInt32(bytes[11]) * 256 == targetProduct else { return false }
    return stride(from: 0, to: bytes.count, by: 128).allSatisfy { offset in bytes[offset..<(offset + 128)].reduce(0, { $0 + Int($1) }) % 256 == 0 }
}

// IOAVService link packet: 16-byte header + 256-byte video payload.
// Native IOAVCreateStringWithVideoLinkData loads depth/encoding/range/EOTF
// at payload +8/+12/+16/+24; bytes +24..<56 must match a real driver element.
func decodeVideoColor(_ bytes: Data, elements: [[String: Any]]) -> [String: Any]? {
    guard bytes.count == 272, Array(bytes[8..<12]) == [1,0,0,0] else { return nil }
    let rawColor = bytes.subdata(in: 24..<56)
    let matches = elements.filter { $0["ElementData"] as? Data == rawColor && $0["IsVirtual"] as? Bool == false }
    guard matches.count == 1, let e = matches.first,
          let depth = e["Depth"] as? Int, [8,10,12,16].contains(depth),
          let encoding = e["PixelEncoding"] as? Int, (0...3).contains(encoding),
          let range = e["DynamicRange"] as? Int, [0,1].contains(range),
          let eotf = e["EOTF"] as? Int, (0...3).contains(eotf) else { return nil }
    return ["bitDepth": depth, "encoding": ["RGB", "YCbCr 4:2:0", "YCbCr 4:2:2", "YCbCr 4:4:4"][encoding], "fullRange": range == 0, "hdr": eotf != 0, "eotf": eotf, "driverElementID": e["ID"] ?? NSNull(), "elementDataBase64": rawColor.base64EncodedString()]
}
