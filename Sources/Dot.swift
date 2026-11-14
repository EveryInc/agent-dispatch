// Sends a written-up recording to the owner's ChatGPT dot, through Clipshot.
//
// Clipshot already runs the server the dot is subscribed to, and only Clipshot can deliver: the subscription and
// its signing secret live in the running app. So this does what Clipshot's "Send Last Recording to Dot" menu item
// does: points `latest` at the recording and opens clipshot://dot. Then it checks Clipshot's own records to see
// that the recording really went: dot.json lists it as sent, and Clipshot's log says how many dots took it.
import AppKit
import Foundation

enum Dot {
    enum Outcome: Equatable {
        case delivered(String)
        /// Clipshot sent it but its log does not confirm ChatGPT accepted it.
        case unconfirmed(String)
        case noSubscription
        /// Clipshot did not act on the request (busy recording, mid-send, or not running).
        case notPickedUp
        case failed(String)
    }

    private static func clipshotState() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: Paths.clipshotState))) as? [String: Any]
    }

    private static let iso = ISO8601DateFormatter()

    static var hasLiveSubscription: Bool {
        let subscriptions = clipshotState()?["subscriptions"] as? [[String: Any]] ?? []
        return subscriptions.contains { ($0["expires"] as? String).flatMap(iso.date(from:)).map { $0 > Date() } ?? false }
    }

    /// The event Clipshot recorded for this recording, if it sent it at or after `after`.
    private static func sharedEvent(for id: String, after: Date) -> String? {
        let shared = clipshotState()?["shared"] as? [[String: Any]] ?? []
        guard let entry = shared.last(where: { $0["id"] as? String == id }),
              let at = (entry["sharedAt"] as? String).flatMap(iso.date(from:)), at >= after.addingTimeInterval(-2) else { return nil }
        return entry["eventID"] as? String
    }

    static func send(_ directory: URL) async -> Outcome {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.md").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path) else {
            return .failed("The recording has not been written up")
        }
        guard hasLiveSubscription else { return .noSubscription }

        // What Clipshot sends is whatever `latest` points at.
        let link = directory.deletingLastPathComponent().appendingPathComponent("latest")
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: directory.lastPathComponent)
        } catch {
            return .failed("Could not point latest at the recording: \(error.localizedDescription)")
        }

        let started = Date()
        let opened = Shell.run("/usr/bin/open", ["-g", "clipshot://dot"], timeout: 20)
        guard opened.status == 0 else { return .failed("Could not reach Clipshot: \(opened.err.trimmingCharacters(in: .whitespacesAndNewlines))") }

        // Clipshot records the recording as sent just before it posts the event.
        let id = directory.lastPathComponent
        var eventID: String?
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let found = sharedEvent(for: id, after: started) { eventID = found; break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let eventID else { return .notPickedUp }

        // "dot event evt_…: delivered to 1 of 1" is written once ChatGPT has answered (up to three tries).
        let logDeadline = Date().addingTimeInterval(50)
        while Date() < logDeadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let log = Shell.run("/usr/bin/log", ["show", "--last", "3m", "--style", "compact", "--predicate",
                                                 "subsystem == \"com.danshipper.clipshot\" AND eventMessage CONTAINS \"\(eventID)\""], timeout: 40)
            guard let line = log.out.split(separator: "\n").last(where: { $0.contains("delivered to") }) else { continue }
            let count = line.components(separatedBy: "delivered to ").last?.split(separator: " ").first.flatMap { Int($0) } ?? 0
            return count > 0 ? .delivered(eventID) : .failed("ChatGPT did not accept the event (\(eventID))")
        }
        return .unconfirmed(eventID)
    }
}
