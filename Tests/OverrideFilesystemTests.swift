import Foundation

// Synthetic executable checks (no XCTest, no device APIs, no modifyOverride).
// Exercises the injectable filesystem core in temp dirs only.
@main
struct OverrideFilesystemTests {
    static var failures = 0
    static func check(_ name: String, _ cond: Bool) {
        print((cond ? "PASS " : "FAIL ") + name)
        if !cond { failures += 1 }
    }
    static func freshRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netekran-override-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
    static func readDict(_ data: Data) throws -> [String: Any] {
        guard let d = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw NetError("bad plist") }
        return d
    }
    static func receipt(_ journal: URL) throws -> OverrideReceipt {
        try JSONDecoder().decode(OverrideReceipt.self, from: Data(contentsOf: journal.appendingPathComponent("receipt.json")))
    }

    static func main() {
        do { try run() } catch { print("FAIL harness threw: \(error)"); failures += 1 }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() throws {
        // 1. Initially absent target: byte-for-byte install, receipt keeps nil original.
        let r1 = try freshRoot(); defer { try? FileManager.default.removeItem(at: r1) }
        let t1 = r1.appendingPathComponent("Overrides/DisplayProductID-238")
        let j1 = r1.appendingPathComponent("Journal")
        _ = try installOverrideEntry(targetURL: t1, journalURL: j1)
        let installed = try Data(contentsOf: t1)
        let d1 = try readDict(installed)
        check("absent target installs exact entry", (d1["scale-resolutions"] as? [Data]) == [exactScaleEntry])
        check("absent target receipt original nil", (try receipt(j1)).original == nil)
        check("installed digest matches receipt", digest(installed) == (try receipt(j1)).installedSHA256)
        // 2. Repeated install idempotent, bytes unchanged.
        let before = installed
        _ = try installOverrideEntry(targetURL: t1, journalURL: j1)
        check("repeated install byte-identical", (try Data(contentsOf: t1)) == before)
        // 3. Remove after absent-origin install deletes target + receipt.
        _ = try removeOverrideEntry(targetURL: t1, journalURL: j1)
        check("remove deletes created target", !FileManager.default.fileExists(atPath: t1.path))
        check("remove deletes receipt", !FileManager.default.fileExists(atPath: j1.appendingPathComponent("receipt.json").path))
        // 4. Repeated remove reports nothing to do.
        _ = try removeOverrideEntry(targetURL: t1, journalURL: j1)
        check("repeated remove no-op", !FileManager.default.fileExists(atPath: t1.path))

        // 5. Foreign data preserved byte-for-byte round trip.
        let r2 = try freshRoot(); defer { try? FileManager.default.removeItem(at: r2) }
        let t2 = r2.appendingPathComponent("Overrides/DisplayProductID-238")
        let j2 = r2.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: t2.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign: [String: Any] = ["DisplayVendorID": 13441, "DisplayProductID": 568, "foreign-key": "keep",
                                      "scale-resolutions": [Data([1,2,3,4,5,6,7,8])]]
        let foreignBytes = try plist(foreign)
        try foreignBytes.write(to: t2, options: .atomic)
        _ = try installOverrideEntry(targetURL: t2, journalURL: j2)
        let d2 = try readDict(try Data(contentsOf: t2))
        check("foreign key preserved", d2["foreign-key"] as? String == "keep")
        check("entry appended after existing", (d2["scale-resolutions"] as? [Data]) == [Data([1,2,3,4,5,6,7,8]), exactScaleEntry])
        check("receipt keeps original bytes", (try receipt(j2)).original == foreignBytes)
        _ = try removeOverrideEntry(targetURL: t2, journalURL: j2)
        check("remove restores original byte-for-byte", (try Data(contentsOf: t2)) == foreignBytes)

        // 6. Interrupted pending state: receipt written, target still == original.
        let r3 = try freshRoot(); defer { try? FileManager.default.removeItem(at: r3) }
        let t3 = r3.appendingPathComponent("Overrides/DisplayProductID-238")
        let j3 = r3.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: t3.deletingLastPathComponent(), withIntermediateDirectories: true)
        try foreignBytes.write(to: t3, options: .atomic)
        // Simulate crash: stage the exact receipt install would write, without touching target.
        let merged = try mergeTargetOverride(foreign)
        let desired = try plist(merged.dictionary)
        try FileManager.default.createDirectory(at: j3, withIntermediateDirectories: true)
        try writeJSON(OverrideReceipt(original: foreignBytes, installedSHA256: digest(desired)), to: j3.appendingPathComponent("receipt.json"))
        _ = try installOverrideEntry(targetURL: t3, journalURL: j3) // must resume, not throw
        check("stale pending receipt resumes install", (try Data(contentsOf: t3)) == desired)
        _ = try removeOverrideEntry(targetURL: t3, journalURL: j3)
        check("post-resume remove restores", (try Data(contentsOf: t3)) == foreignBytes)

        // 7. Remove cleans unchanged pending receipt without touching target.
        let r4 = try freshRoot(); defer { try? FileManager.default.removeItem(at: r4) }
        let t4 = r4.appendingPathComponent("Overrides/DisplayProductID-238")
        let j4 = r4.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: t4.deletingLastPathComponent(), withIntermediateDirectories: true)
        try foreignBytes.write(to: t4, options: .atomic)
        try FileManager.default.createDirectory(at: j4, withIntermediateDirectories: true)
        try writeJSON(OverrideReceipt(original: foreignBytes, installedSHA256: digest(desired)), to: j4.appendingPathComponent("receipt.json"))
        _ = try removeOverrideEntry(targetURL: t4, journalURL: j4)
        check("remove cleans pending receipt, target untouched",
            (try Data(contentsOf: t4)) == foreignBytes &&
            !FileManager.default.fileExists(atPath: j4.appendingPathComponent("receipt.json").path))

        // 8. Malformed receipt fails closed, target preserved.
        let r5 = try freshRoot(); defer { try? FileManager.default.removeItem(at: r5) }
        let t5 = r5.appendingPathComponent("Overrides/DisplayProductID-238")
        let j5 = r5.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: t5.deletingLastPathComponent(), withIntermediateDirectories: true)
        try foreignBytes.write(to: t5, options: .atomic)
        try FileManager.default.createDirectory(at: j5, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: j5.appendingPathComponent("receipt.json"), options: .atomic)
        var installThrew = false
        do { _ = try installOverrideEntry(targetURL: t5, journalURL: j5) } catch { installThrew = true }
        var removeThrew = false
        do { _ = try removeOverrideEntry(targetURL: t5, journalURL: j5) } catch { removeThrew = true }
        check("malformed receipt install fails closed", installThrew && (try? Data(contentsOf: t5)) == Optional(foreignBytes))
        check("malformed receipt remove fails closed", removeThrew && (try? Data(contentsOf: t5)) == Optional(foreignBytes))

        // 9. External edits preserved: foreign change after install blocks remove.
        let r6 = try freshRoot(); defer { try? FileManager.default.removeItem(at: r6) }
        let t6 = r6.appendingPathComponent("Overrides/DisplayProductID-238")
        let j6 = r6.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: t6.deletingLastPathComponent(), withIntermediateDirectories: true)
        try foreignBytes.write(to: t6, options: .atomic)
        _ = try installOverrideEntry(targetURL: t6, journalURL: j6)
        var edited = try readDict(try Data(contentsOf: t6))
        edited["intruder"] = "external"
        let editedBytes = try plist(edited)
        try editedBytes.write(to: t6, options: .atomic)
        var blocked = false
        do { _ = try removeOverrideEntry(targetURL: t6, journalURL: j6) } catch { blocked = true }
        check("external edit blocks remove, bytes kept", blocked && (try? Data(contentsOf: t6)) == Optional(editedBytes))
        check("receipt retained after refusal", FileManager.default.fileExists(atPath: j6.appendingPathComponent("receipt.json").path))

        // 10. Malformed target plist + foreign identity fail closed with no receipt.
        let r7 = try freshRoot(); defer { try? FileManager.default.removeItem(at: r7) }
        let t7 = r7.appendingPathComponent("Overrides/DisplayProductID-238")
        let j7 = r7.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: t7.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: t7, options: .atomic)
        var badPlistThrew = false
        do { _ = try installOverrideEntry(targetURL: t7, journalURL: j7) } catch { badPlistThrew = true }
        check("malformed plist fails closed, no receipt", badPlistThrew &&
            !FileManager.default.fileExists(atPath: j7.appendingPathComponent("receipt.json").path))
        let wrongID: [String: Any] = ["DisplayVendorID": 999, "DisplayProductID": 568]
        try (try plist(wrongID)).write(to: t7, options: .atomic)
        var wrongIDThrew = false
        do { _ = try installOverrideEntry(targetURL: t7, journalURL: j7) } catch { wrongIDThrew = true }
        check("foreign identity refused", wrongIDThrew)
        let link = r7.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t7)
        var symlinkBlocked = false
        do { _ = try installOverrideEntry(targetURL: link, journalURL: j7) } catch { symlinkBlocked = true }
        check("target symlink refused", symlinkBlocked)
    }
}
