// Shared plumbing: where things live, the log, the state file, the lock, and running other programs.
import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// State, log and lock. Tests point this somewhere disposable with --support.
    static var support = home.appendingPathComponent("Library/Application Support/PhoneRecordings", isDirectory: true)
    static var state: URL { support.appendingPathComponent("state.json") }
    static var log: URL { support.appendingPathComponent("watcher.log") }
    static var lock: URL { support.appendingPathComponent("lock") }
    static let clipshotState = home.appendingPathComponent("Library/Application Support/Clipshot/dot.json")

    /// Clipshot's recordings folder: imported recordings go beside the Mac's own, in the same format.
    static var recordings: URL = {
        if let custom = UserDefaults(suiteName: "com.danshipper.clipshot")?.string(forKey: "recordingsFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Recordings", isDirectory: true)
    }()
}

enum Log {
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func line(_ text: String) {
        let line = "\(stamp.string(from: Date())) \(text)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        // Keep the log small: start over past 2 MB, with one older generation.
        if let size = (try? FileManager.default.attributesOfItem(atPath: Paths.log.path)[.size] as? NSNumber)?.intValue, size > 2_000_000 {
            let old = Paths.log.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: Paths.log, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: Paths.log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Paths.log)
        }
    }
}

/// What the judge decided about one recording.
struct Decision: Codable {
    var send: Bool
    var reason: String
    /// What the owner seems to be asking for, in a sentence or two. Empty when nothing is being asked.
    var request: String
    /// "claude", or "rule" when the model could not be reached.
    var by: String
}

/// One screen recording found in Photos, and how far it has got.
struct Item: Codable {
    enum Status: String, Codable { case found, written, sendPending, sent, skipped, failed }

    var id: String
    var filename: String
    var created: Date
    var status: Status = .found
    var folder: String?
    var decision: Decision?
    var eventID: String?
    var attempts = 0
    var note: String?
    var updated = Date()

    var isSettled: Bool { status == .sent || status == .skipped || status == .failed }
}

struct WatcherState: Codable {
    /// Only recordings made after this are looked at, so installing the watcher does not send old ones.
    var since: Date
    var items: [String: Item] = [:]
    /// When the background job last looked, and how many videos from the last 30 days Photos showed it:
    /// proof that it runs and can see the library.
    var lastPass: Date?
    var lastPassVideos: Int?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load() -> WatcherState {
        if let data = try? Data(contentsOf: Paths.state), let state = try? decoder.decode(WatcherState.self, from: data) { return state }
        return WatcherState(since: Date())
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(self) { try? data.write(to: Paths.state, options: .atomic) }
    }
}

/// One pass at a time: a run started by hand must not overlap the background one.
final class RunLock {
    private var descriptor: Int32 = -1

    func acquire() -> Bool {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        descriptor = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

enum Shell {
    /// Runs a program to completion (or until `timeout`), returning its exit status and output.
    static func run(_ path: String, _ arguments: [String], directory: URL? = nil, timeout: TimeInterval = 120,
                    environment: [String: String]? = nil) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "could not start \(path): \(error.localizedDescription)") }

        // Read both pipes while it runs, so a chatty program cannot fill one and stall.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = data } else { errData = data }
                group.leave()
            }
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                         : String(format: "%02d:%02d", total / 60, total % 60)
}
