import Foundation

// Synthetic executable checks (no XCTest); run via swiftc + binary.
@main
struct ProfileTests {
    static func check(_ name: String, _ cond: Bool, failures: inout Int) {
        print((cond ? "PASS " : "FAIL ") + name)
        if !cond { failures += 1 }
    }
    static func exact() -> DisplayProfile {
        DisplayProfile(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 100, bitDepth: 10, hdr: false, encoding: "RGB", fullRange: true, mirrored: false, identity: "stable-test-id")
    }
    static func main() {
        var failures = 0
        let ok = assessTarget(exact())
        check("accept exact target", ok.matchesTarget && ok.resolutionVerified && ok.refreshVerified && ok.colorVerified && ok.reasons.isEmpty, failures: &failures)
        var lo = exact(); lo.pixelWidth = 1920; lo.pixelHeight = 1080
        check("reject LoDPI", !assessTarget(lo).matchesTarget && !assessTarget(lo).resolutionVerified, failures: &failures)
        var odd = exact(); odd.logicalWidth = 1904; odd.logicalHeight = 1071
        check("reject 1904x1071", !assessTarget(odd).matchesTarget && !assessTarget(odd).resolutionVerified, failures: &failures)
        var hz = exact(); hz.refreshHz = 60
        check("reject 60Hz", !assessTarget(hz).matchesTarget && !assessTarget(hz).refreshVerified, failures: &failures)
        var mir = exact(); mir.mirrored = true
        check("reject mirrored", !assessTarget(mir).matchesTarget, failures: &failures)
        var b = exact(); b.bitDepth = nil
        check("unknown bitDepth never verifies", !assessTarget(b).colorVerified && !assessTarget(b).matchesTarget, failures: &failures)
        var h = exact(); h.hdr = nil
        check("unknown hdr never verifies", !assessTarget(h).colorVerified && !assessTarget(h).matchesTarget, failures: &failures)
        var e = exact(); e.encoding = nil
        check("unknown encoding never verifies", !assessTarget(e).colorVerified && !assessTarget(e).matchesTarget, failures: &failures)
        var f = exact(); f.fullRange = nil
        check("unknown fullRange never verifies", !assessTarget(f).colorVerified && !assessTarget(f).matchesTarget, failures: &failures)
        var lc = exact(); lc.encoding = "rgb"
        check("encoding case-insensitive", assessTarget(lc).colorVerified && assessTarget(lc).matchesTarget, failures: &failures)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
