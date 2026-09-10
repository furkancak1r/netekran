#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/NetEkran.app/Contents/MacOS build/NetEkran.app/Contents/Resources
swiftc -O -module-cache-path /tmp/netekran-swift-cache Sources/*.swift -o build/NetEkran.app/Contents/MacOS/NetEkran
cat > build/NetEkran.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tr.netekran.app</string>
<key>CFBundleName</key><string>NetEkran</string>
<key>CFBundleDisplayName</key><string>NetEkran</string>
<key>CFBundleExecutable</key><string>NetEkran</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>tr</string>
</dict></plist>
PLIST
codesign --force --sign - build/NetEkran.app
swiftc -module-cache-path /tmp/netekran-swift-cache Sources/Profile.swift Tests/ProfileTests.swift -o build/profile-tests
build/profile-tests
swiftc -module-cache-path /tmp/netekran-swift-cache Sources/Profile.swift Sources/Probe.swift Sources/LinkProbe.swift Sources/Output.swift Sources/Runtime.swift Sources/ICC.swift Sources/Override.swift Tests/SafetyTests.swift -o build/safety-tests
build/safety-tests
swiftc -module-cache-path /tmp/netekran-swift-cache Sources/Profile.swift Sources/Probe.swift Sources/LinkProbe.swift Sources/Output.swift Sources/Runtime.swift Sources/ICC.swift Tests/WatchdogProcessTests.swift -o build/watchdog-process-tests
build/watchdog-process-tests

swiftc -module-cache-path /tmp/netekran-swift-cache Sources/Profile.swift Sources/Probe.swift Sources/LinkProbe.swift Sources/Output.swift Sources/Runtime.swift Sources/ICC.swift Sources/Override.swift Tests/OverrideFilesystemTests.swift -o build/override-filesystem-tests
build/override-filesystem-tests
