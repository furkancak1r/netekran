import AppKit

@main struct BrightnessTests {
    static func main() throws {
        let args = CommandLine.arguments
        // Exercise the real bounded subprocess client with synthetic replies only.
        if args.count > 1 {
            if args[1] == "--builtin-auto-brightness" {
                precondition(args.count == 3 && ["on", "off"].contains(args[2]))
                print(String(data: try JSONEncoder().encode(BrightnessReading(current: 50, maximum: 100, automatic: args[2] == "on")), encoding: .utf8)!)
                return
            }
            let value = args.count == 3 ? Double(args[2])! : 50
            if value == 13 { Thread.sleep(forTimeInterval: 10) }
            if value == 14 { fputs("synthetic DDC failure\n", stderr); exit(1) }
            if value == 15 { print("{\"current\":0,\"maximum\":0}"); return }
            print(String(data: try JSONEncoder().encode(BrightnessReading(current: Int(value), maximum: 100, automatic: args[1].hasPrefix("--builtin-") ? true : nil)), encoding: .utf8)!)
            return
        }
        precondition(brightnessPacket() == [0x82, 0x01, 0x10, 0xac])
        let packet = brightnessPacket(value: 300)
        precondition(packet[3] == 1 && packet[4] == 44 && packet.reduce(UInt8(0x6e ^ 0x51), ^) == 0)
        var reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 1, 0x2c, 0, 150]
        func checked(_ bytes: [UInt8]) -> [UInt8] { bytes + [bytes.reduce(UInt8(0x50), ^)] }
        let reading = try decodeBrightness(checked(reply))
        precondition(reading.current == 150 && reading.maximum == 300 && reading.percent == 50)
        let scaled = try brightnessValue(percent: 50, maximum: 300)
        precondition(scaled == 150)
        for value in [-1.0, 101, .nan, .infinity] { precondition((try? brightnessValue(percent: value, maximum: 100)) == nil) }
        precondition((try? brightnessValue(percent: 50, maximum: 0)) == nil)
        precondition((try? brightnessValue(percent: 50, maximum: 65536)) == nil)
        precondition((try? decodeBrightness(Array(checked(reply).dropLast()))) == nil)
        var corrupted = checked(reply); corrupted[10] ^= 1
        precondition((try? decodeBrightness(corrupted)) == nil)
        for (index, value) in [(0, 0x51), (1, 0x87), (2, 0x03), (3, 1), (4, 0x12), (5, 1)] {
            var changed = reply; changed[index] = UInt8(value)
            precondition((try? decodeBrightness(checked(changed))) == nil)
        }
        reply[6] = 0; reply[7] = 0
        precondition((try? decodeBrightness(checked(reply))) == nil)
        reply[7] = 100
        precondition((try? decodeBrightness(checked(reply))) == nil)
        print("PASS DDC packets: standard checksum, 16-bit scaling, invalid/unsupported/wrong-feature/range replies rejected")
        let read = try runBrightnessRequest(percent: nil), write = try runBrightnessRequest(percent: 75)
        precondition(read.current == 50 && write.current == 75)
        precondition((try? runBrightnessRequest(percent: 14)) == nil)
        precondition((try? runBrightnessRequest(percent: 15)) == nil)
        let nativeRead = try runBrightnessRequest(percent: nil, builtIn: true)
        let nativeWrite = try runBrightnessRequest(percent: 60, builtIn: true)
        let autoOn = try runBrightnessRequest(percent: nil, builtIn: true, automatic: true)
        let autoOff = try runBrightnessRequest(percent: nil, builtIn: true, automatic: false)
        precondition(nativeRead.current == 50 && nativeRead.automatic == true)
        precondition(nativeWrite.current == 60 && nativeWrite.automatic == true)
        precondition(autoOn.automatic == true && autoOff.automatic == false)
        precondition((try? runBrightnessRequest(percent: nil, automatic: true)) == nil)
        precondition((try? runBrightnessRequest(percent: 50, builtIn: true, automatic: true)) == nil)
        for value in [-1.0, 101, .nan, .infinity] {
            precondition((try? runBrightnessRequest(percent: value, builtIn: true)) == nil)
            precondition((try? builtInBrightnessRequest(percent: value)) == nil)
        }
        precondition((try? runBrightnessRequest(percent: 14, builtIn: true)) == nil)
        precondition((try? runBrightnessRequest(percent: 15, builtIn: true)) == nil)
        print("PASS built-in brightness and automatic on/off: isolated child routing, readback and invalid requests")
        _ = NSApplication.shared
        let menu = NSMenu(); menu.autoenablesItems = false
        var allowed = true
        let monitorControl = BrightnessControl(builtIn: false) { allowed }
        let macControl = BrightnessControl(builtIn: true) { allowed }
        monitorControl.add(to: menu); macControl.add(to: menu)
        let sliders = menu.items.compactMap { $0.view?.subviews.compactMap { $0 as? NSSlider }.first }
        precondition(menu.items.count == 3 && sliders.count == 2)
        let automaticItem = menu.items[2]
        precondition(sliders.allSatisfy { !$0.isEnabled } && automaticItem.state == .mixed && !automaticItem.isEnabled)
        func awaitUI(_ ready: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !ready() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(ready())
        }
        monitorControl.refresh(); macControl.refresh()
        awaitUI { sliders.allSatisfy { $0.isEnabled && $0.doubleValue == 50 } && automaticItem.isEnabled }
        precondition(automaticItem.state == .on)
        NSApp.sendAction(automaticItem.action!, to: automaticItem.target, from: automaticItem)
        awaitUI { automaticItem.isEnabled && automaticItem.state == .off }
        sliders[1].doubleValue = 65
        NSApp.sendAction(sliders[1].action!, to: sliders[1].target, from: sliders[1])
        awaitUI { automaticItem.isEnabled && sliders[1].doubleValue == 65 }
        precondition(sliders[0].doubleValue == 50)
        allowed = false; monitorControl.refresh(); macControl.refresh()
        precondition(sliders.allSatisfy { !$0.isEnabled } && !automaticItem.isEnabled)
        print("PASS menu: two independent sliders, system checkbox readback, real actions and disabled controls")
        let start = ProcessInfo.processInfo.systemUptime
        precondition((try? runBrightnessRequest(percent: 13)) == nil)
        precondition(ProcessInfo.processInfo.systemUptime - start < 6)
        print("PASS brightness subprocess: read/write JSON, child errors, invalid reply and bounded timeout; no hardware calls")
    }
}
