import Foundation

@main struct SafetyTests {
    static func main() throws {
        let original: [String: Any] = ["DisplayVendorID": 13441, "DisplayProductID": 568, "foreign-key": "keep", "scale-resolutions": [Data([1,2,3,4,5,6,7,8])]]
        let merged = try mergeTargetOverride(original)
        precondition(merged.added)
        precondition(merged.dictionary["foreign-key"] as? String == "keep")
        precondition((merged.dictionary["scale-resolutions"] as? [Data]) == [Data([1,2,3,4,5,6,7,8]), exactScaleEntry])
        precondition(exactScaleEntry.map { String(format: "%02x", $0) }.joined() == "00000f00000008700000000900200000")
        let repeated = try mergeTargetOverride(merged.dictionary)
        precondition(!repeated.added)
        precondition(NSDictionary(dictionary: repeated.dictionary).isEqual(to: merged.dictionary))
        let fresh = try mergeTargetOverride(nil)
        precondition((fresh.dictionary["scale-resolutions"] as? [Data])?.count == 1)
        for invalid: [String: Any] in [["DisplayVendorID": 13442,"DisplayProductID":568], ["DisplayVendorID":13441,"DisplayProductID":568,"scale-resolutions":["bad"]]] {
            do { _ = try mergeTargetOverride(invalid); fatalError("malformed/foreign override accepted") } catch {}
        }
        print("PASS override: exact bytes, merge preserves foreign data, idempotent, malformed/foreign identity rejected")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netekran-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        var time = 0.0
        precondition(!waitForConfirmation(directory: dir, clock: { time }, pause: { time += 1 }))
        precondition(time == 20)
        time = 0
        let accepted = waitForConfirmation(directory: dir, clock: { time }, pause: {
            time += 1
            if time == 19 { try! Data().write(to: dir.appendingPathComponent("confirm")) }
        })
        precondition(accepted && time == 19)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("confirm"))
        time = 0
        let late = waitForConfirmation(directory: dir, clock: { time }, pause: {
            time += 1
            if time == 20 { try! Data().write(to: dir.appendingPathComponent("confirm")) }
        })
        precondition(!late)
        try Data().write(to: dir.appendingPathComponent("cancel"))
        precondition(!waitForConfirmation(directory: dir))
        print("PASS watchdog: 20-second deadline, timely confirmation, late confirmation rejected, cancel wins")
        var p = DisplayProfile(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 100, bitDepth: 10, hdr: false, encoding: "RGB", fullRange: true, mirrored: false, identity: "synthetic")
        for rate in [Double.nan, Double.infinity, 99.0, 60.0] { p.refreshHz = rate; precondition(!assessTarget(p).matchesTarget) }
        p.refreshHz = 100; p.bitDepth = 8; precondition(!assessTarget(p).matchesTarget)
        p.bitDepth = 10; p.hdr = true; precondition(!assessTarget(p).matchesTarget)
        p.hdr = false; p.encoding = "YCbCr"; precondition(!assessTarget(p).matchesTarget)
        p.encoding = "RGB"; p.fullRange = false; precondition(!assessTarget(p).matchesTarget)
        var edid = [UInt8](repeating: 0, count: 128)
        edid.replaceSubrange(0..<8, with: [0,255,255,255,255,255,255,0])
        edid[8] = 0x34; edid[9] = 0x81; edid[10] = 0x38; edid[11] = 0x02
        edid[127] = UInt8((256 - edid.reduce(0, { $0 + Int($1) }) % 256) % 256)
        precondition(validTargetEDID(Data(edid)))
        edid[127] ^= 1; precondition(!validTargetEDID(Data(edid)))
        precondition(!validTargetEDID(Data([0])))
        var video = Data(repeating: 0, count: 272); video[8] = 1
        var raw = Data(repeating: 0, count: 32); raw[0] = 10
        video.replaceSubrange(24..<56, with: raw)
        let element: [String: Any] = ["ElementData": raw, "IsVirtual": false, "Depth": 10, "PixelEncoding": 0, "DynamicRange": 0, "EOTF": 0, "ID": 76]
        precondition(decodeVideoColor(video, elements: [element])?["encoding"] as? String == "RGB")
        video[8] = 0; precondition(decodeVideoColor(video, elements: [element]) == nil)
        video[8] = 1; precondition(decodeVideoColor(video, elements: [element, element]) == nil)
        precondition(decodeVideoColor(Data([1]), elements: [element]) == nil)
        video[24] = 8; precondition(decodeVideoColor(video, elements: [element]) == nil)
        precondition(OutputRecord(words: [10,1,0,0]).target)
        for w: [UInt32] in [[8,1,0,0],[10,0,0,0],[10,0,0,1],[10,1,1,0],[]] { precondition(!OutputRecord(words: w).target) }
        var icc = Data(repeating: 0, count: 160); icc.replaceSubrange(36..<40, with: Data("acsp".utf8))
        let normalized = iccWithoutCreationTime(icc)
        icc[25] = 42; precondition(iccWithoutCreationTime(icc) == normalized)
        icc[140] = 42; precondition(iccWithoutCreationTime(icc) != normalized)
        precondition(iccWithoutCreationTime(Data([0])) == nil)
        print("PASS ICC: creation timestamp ignored, color tag mutation still rejected")
        let originalValues = ["iccURL": "file:///original.icc", "iccContentSHA256": "original", "iccFileContentSHA256": "original", "gammaSHA256": "gamma", "driverDither": "1", "driverBrightness": "65536"]
        var copiedValues = originalValues; copiedValues["iccURL"] = "file:///preserved.icc"
        precondition(!preservedValues(originalValues, match: copiedValues))
        precondition(preservedValues(originalValues, match: copiedValues, selectedURL: "file:///preserved.icc"))
        for key in ["iccContentSHA256", "iccFileContentSHA256", "gammaSHA256", "driverDither", "driverBrightness"] {
            var changed = copiedValues; changed[key] = "changed"
            precondition(!preservedValues(originalValues, match: changed, selectedURL: "file:///preserved.icc"))
            changed.removeValue(forKey: key)
            precondition(!preservedValues(originalValues, match: changed, selectedURL: "file:///preserved.icc"))
        }
        print("PASS preserved ICC copy: planned URL allowed, profile/gamma/dither/brightness mutations or missing reads rejected")
        let factoryFile = dir.appendingPathComponent("factory.icc")
        try icc.write(to: factoryFile)
        let selection = ICCSelection(profileID: "synthetic", customURL: nil, activeURL: factoryFile.absoluteString, factoryURL: factoryFile.absoluteString)
        let pinned = try preservedICCSelection(selection, storage: dir)
        let pinnedFile = URL(string: pinned.activeURL)!
        let pinnedBytes = try Data(contentsOf: pinnedFile)
        precondition(pinnedBytes == icc && pinned.activeURL != selection.activeURL)
        let repeatedPin = try preservedICCSelection(selection, storage: dir)
        precondition(repeatedPin == pinned)
        let alreadyCustom = try preservedICCSelection(pinned, storage: dir)
        precondition(alreadyCustom == pinned)
        try Data([0]).write(to: pinnedFile)
        precondition((try? preservedICCSelection(selection, storage: dir)) == nil)
        let unknownFactory = ICCSelection(profileID: "synthetic", customURL: nil, activeURL: factoryFile.absoluteString, factoryURL: nil)
        precondition((try? preservedICCSelection(unknownFactory, storage: dir)) == nil)
        print("PASS ICC filesystem: byte-identical copy, idempotent reuse, custom retained, changed copy and missing factory rejected")
        let approved = ApprovedProfile(uuid: "synthetic", selection: pinned, iccValues: ["iccURL": pinned.activeURL, "iccFileContentSHA256": digest(iccWithoutCreationTime(icc)!)])
        precondition((try? validatedApprovedICC(approved)) == nil)
        try icc.write(to: pinnedFile)
        try validatedApprovedICC(approved)
        var exact = DisplayProfile(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 100, bitDepth: 10, hdr: false, encoding: "RGB", fullRange: true, mirrored: false, identity: "synthetic")
        let stable = try automaticRecoveryNeeded(exact, selection: pinned, approved: approved, preserved: approved.iccValues)
        precondition(!stable)
        let resetICC = try automaticRecoveryNeeded(exact, selection: selection, approved: approved, preserved: [:])
        precondition(resetICC)
        exact.bitDepth = 8
        let wrongDepth = try automaticRecoveryNeeded(exact, selection: pinned, approved: approved, preserved: approved.iccValues)
        precondition(wrongDepth)
        let foreignSelection = ICCSelection(profileID: "synthetic", customURL: "file:///user-choice.icc", activeURL: "file:///user-choice.icc", factoryURL: selection.factoryURL)
        precondition((try? automaticRecoveryNeeded(exact, selection: foreignSelection, approved: approved, preserved: [:])) == nil)
        exact.identity = "other"
        precondition((try? automaticRecoveryNeeded(exact, selection: pinned, approved: approved, preserved: [:])) == nil)
        print("PASS automatic protection: stable no-op, color/ICC drift detected, foreign selection/identity and changed approved ICC refused")
        print("PASS video: audio packets, mismatched/ambiguous colors and non-target output descriptors rejected")
        print("PASS EDID: synthetic target identity/checksum accepted, corrupt/truncated rejected")
        print("PASS validation: NaN/infinity, 8-bit, HDR, YCbCr, limited range rejected")
    }
}
