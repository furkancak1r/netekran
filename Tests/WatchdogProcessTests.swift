import Foundation

@main struct WatchdogProcessTests {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--blocked-hardware" {
            while true { Thread.sleep(forTimeInterval: 60) }
        }
        if args.count == 3 {
            let dir = URL(fileURLWithPath: args[2])
            if args[1] == "--transaction-worker" {
                try requireTransactionLock(dir.appendingPathComponent("lock"))
                try Data("simulated-new-mode".utf8).write(to: dir.appendingPathComponent("mode"))
                try state(dir, "applying", "Synthetic blocked hardware call")
                while true { Thread.sleep(forTimeInterval: 60) }
            }
            if args[1] == "--rollback-worker" {
                try requireTransactionLock(dir.appendingPathComponent("lock"))
                try Data("restored".utf8).write(to: dir.appendingPathComponent("mode"))
                try state(dir, "reverted", "Synthetic rollback complete")
                return
            }
            if args[1] == "--guard" {
                try Data("simulated-new-mode".utf8).write(to: dir.appendingPathComponent("mode"))
                try Data().write(to: dir.appendingPathComponent("ready"))
                let confirmed = waitForConfirmation(directory: dir)
                try Data((confirmed ? "kept" : "restored").utf8).write(to: dir.appendingPathComponent("mode"), options: .atomic)
                return
            }
            if args[1] == "--ui" {
                let guardian = Process(); guardian.executableURL = URL(fileURLWithPath: args[0]); guardian.arguments = ["--guard", dir.path]
                try guardian.run()
                while true { Thread.sleep(forTimeInterval: 1) }
            }
        }
        let blocked = Process(); blocked.executableURL = URL(fileURLWithPath: args[0]); blocked.arguments = ["--blocked-hardware"]
        try blocked.run()
        let started = ProcessInfo.processInfo.systemUptime
        precondition(!waitForWorker(blocked, timeout: 0.15))
        precondition(stopWorker(blocked), "blocked hardware child was not stopped")
        precondition(ProcessInfo.processInfo.systemUptime - started < 3)
        precondition(blocked.terminationReason == .uncaughtSignal && blocked.terminationStatus == SIGKILL)
        print("PASS blocked hardware child: independent timeout and termination; no display API invoked")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netekran-orphan-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runWatchdog(dir, lockURL: dir.appendingPathComponent("lock"), applyTimeout: 0.5, recoveryTimeout: 3)
        precondition((try? String(contentsOf: dir.appendingPathComponent("mode"), encoding: .utf8)) == "restored")
        let recovered = try JSONDecoder().decode(TransactionState.self, from: Data(contentsOf: dir.appendingPathComponent("state.json")))
        precondition(recovered.status == "reverted")
        print("PASS production supervisor: blocked synthetic apply killed, separate recovery process restored state")
        let ui = Process(); ui.executableURL = URL(fileURLWithPath: args[0]); ui.arguments = ["--ui", dir.path]; try ui.run()
        let start = ProcessInfo.processInfo.systemUptime
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("ready").path) && ProcessInfo.processInfo.systemUptime - start < 5 { Thread.sleep(forTimeInterval: 0.05) }
        precondition(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ready").path), "guardian not ready")
        kill(ui.processIdentifier, SIGKILL); ui.waitUntilExit()
        while (try? String(contentsOf: dir.appendingPathComponent("mode"), encoding: .utf8)) != "restored" && ProcessInfo.processInfo.systemUptime - start < 25 { Thread.sleep(forTimeInterval: 0.1) }
        precondition((try? String(contentsOf: dir.appendingPathComponent("mode"), encoding: .utf8)) == "restored", "orphan guardian failed")
        print("PASS process isolation: simulated UI killed with SIGKILL; production confirmation loop timed out and simulated mode restored after 20 seconds. No physical display changed.")
    }
}
