import Foundation

// ponytail: foundation-only pure validation; unknown color fields never verify (no fallback).
public struct DisplayProfile: Codable {
    public var logicalWidth: Int
    public var logicalHeight: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshHz: Double
    public var bitDepth: Int?
    public var hdr: Bool?
    public var encoding: String?
    public var fullRange: Bool?
    public var mirrored: Bool
    public var identity: String

    public init(logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int, refreshHz: Double, bitDepth: Int?, hdr: Bool?, encoding: String?, fullRange: Bool?, mirrored: Bool, identity: String) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshHz = refreshHz
        self.bitDepth = bitDepth
        self.hdr = hdr
        self.encoding = encoding
        self.fullRange = fullRange
        self.mirrored = mirrored
        self.identity = identity
    }
}

public struct ProfileAssessment {
    public var resolutionVerified: Bool
    public var refreshVerified: Bool
    public var colorVerified: Bool
    public var matchesTarget: Bool
    public var reasons: [String]
}

public func assessTarget(_ p: DisplayProfile) -> ProfileAssessment {
    var reasons: [String] = []
    let resolutionVerified = p.logicalWidth == 1920 && p.logicalHeight == 1080 && p.pixelWidth == 3840 && p.pixelHeight == 2160
    if !resolutionVerified { reasons.append("resolution != 1920x1080 logical + 3840x2160 pixel") }
    let refreshVerified = abs(p.refreshHz - 100) < 0.1
    if !refreshVerified { reasons.append("refresh != 100Hz") }
    var colorVerified = true
    if p.bitDepth != 10 { colorVerified = false; reasons.append("bitDepth != 10") }
    if p.hdr != false { colorVerified = false; reasons.append("hdr != SDR(false)") }
    if p.encoding?.lowercased() != "rgb" { colorVerified = false; reasons.append("encoding != RGB") }
    if p.fullRange != true { colorVerified = false; reasons.append("range != full") }
    if p.mirrored { reasons.append("mirrored must be false") }
    let matchesTarget = resolutionVerified && refreshVerified && colorVerified && !p.mirrored
    return ProfileAssessment(resolutionVerified: resolutionVerified, refreshVerified: refreshVerified, colorVerified: colorVerified, matchesTarget: matchesTarget, reasons: reasons)
}
