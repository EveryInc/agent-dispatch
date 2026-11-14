// PhoneRecordings: watches Photos for screen recordings made on the owner's iPhone and, when one is them asking an
// agent to do something, sends it to their ChatGPT dot through Clipshot.
//
//   run      [--dry-run] [--since ISO]               one pass: find new recordings, write them up, judge, send. The LaunchAgent runs this.
//   list     [--days N]                  the videos Photos has from the last N days, and which count as screen recordings
//   process  --file movie [--send] [--test] [--no-model] [--recordings dir]
//                                        the same pipeline on a movie file, without Photos (for testing)
//   status                               what has been seen and what happened to it
//
// Global: --support dir (state, log and lock somewhere else).
import AppKit
import Foundation
import Photos

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func flag(_ name: String) -> Bool { arguments.contains(name) }

if let support = option("--support") { Paths.support = URL(fileURLWithPath: support, isDirectory: true) }
if let recordings = option("--recordings") { Paths.recordings = URL(fileURLWithPath: recordings, isDirectory: true) }
if flag("--no-model") { Judge.useModel = false }

/// A new folder named like Clipshot's own, e.g. `2026-11-14-1002-iphone`.
func makeDirectory(for date: Date) throws -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    let base = formatter.string(from: date) + "-iphone"
    var candidate = Paths.recordings.appendingPathComponent(base, isDirectory: true)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = Paths.recordings.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
        suffix += 1
    }
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    return candidate
}

func describe(_ outcome: Dot.Outcome) -> String {
    switch outcome {
    case .delivered(let event): return "delivered to the dot (\(event))"
    case .unconfirmed(let event): return "sent by Clipshot (\(event)); its log did not confirm ChatGPT took it"
    case .noSubscription: return "no dot is subscribed to Clipshot"
    case .notPickedUp: return "Clipshot did not pick it up (recording, busy, or not running)"
    case .failed(let reason): return "failed: \(reason)"
    }
}

/// Takes one recording as far as it will go this pass.
func handle(_ asset: PHAsset, _ item: inout Item, dryRun: Bool) async {
    item.updated = Date()
    let written = item.folder.map { FileManager.default.fileExists(atPath: $0 + "/notes.md") } ?? false
    if !written {
        guard let directory = try? makeDirectory(for: item.created) else {
            item.note = "Could not make a folder in \(Paths.recordings.path)"
            return
        }
        let movie: URL
        do {
            movie = try await Library.export(asset, to: directory)
        } catch {
            // Usually the original has not finished arriving from iCloud. Try again next pass.
            try? FileManager.default.removeItem(at: directory)
            item.attempts += 1
            item.note = "Not available yet: \(error.localizedDescription)"
            if item.attempts >= 60 { item.status = .failed }
            Log.line("\(item.filename): \(item.note ?? "") (try \(item.attempts))")
            return
        }
        Log.line("\(item.filename): copied out, writing up in \(directory.lastPathComponent)")
        let extract = await Writeup.extract(movie: movie, started: item.created)
        let decision = Judge.decide(extract)
        Writeup.write(extract, source: item.filename, decision: decision, test: false)
        item.folder = directory.path
        item.decision = decision
        item.status = .written
        item.attempts = 0
        Log.line("\(item.filename): \(clock(extract.duration)), \(extract.wordCount) words, \(extract.stills.count) stills; "
                 + "\(decision.send ? "SEND" : "SKIP") by \(decision.by): \(decision.reason)")
    }
    guard let folder = item.folder, let decision = item.decision else { return }
    guard decision.send else {
        item.status = .skipped
        item.note = decision.reason
        return
    }
    if dryRun {
        Log.line("\(item.filename): dry run, not sending")
        return
    }
    let outcome = await Dot.send(URL(fileURLWithPath: folder, isDirectory: true))
    Log.line("\(item.filename): \(describe(outcome))")
    switch outcome {
    case .delivered(let event), .unconfirmed(let event):
        item.status = .sent
        item.eventID = event
        item.note = describe(outcome)
    case .noSubscription, .notPickedUp, .failed:
        item.status = .sendPending
        item.attempts += 1
        item.note = describe(outcome)
        // About a day of trying at one pass a minute, backing off below.
        if item.attempts >= 40 { item.status = .failed }
    }
}

func run() async -> Int32 {
    let lock = RunLock()
    guard lock.acquire() else { return 0 } // another pass is still going
    guard Library.authorize() else {
        Log.line("No access to Photos. Allow PhoneRecordings in System Settings › Privacy & Security › Photos.")
        return 1
    }
    let dryRun = flag("--dry-run")
    var state = WatcherState.load()
    // Testing only: look further back than the watcher normally does.
    if let since = option("--since").flatMap({ ISO8601DateFormatter().date(from: $0) }) { state.since = since }
    if !FileManager.default.fileExists(atPath: Paths.state.path) {
        state.save()
        Log.line("First run: watching for iPhone screen recordings made from now on.")
    }

    if !dryRun {
        state.lastPass = Date()
        state.lastPassVideos = Library.videos(since: Date().addingTimeInterval(-30 * 86400)).count
        state.save()
    }

    for asset in Library.videos(since: state.since) {
        let id = asset.localIdentifier
        var item: Item
        if let known = state.items[id] {
            item = known
        } else {
            let name = Library.filename(of: asset)
            guard Library.isScreenRecording(asset, filename: name) else { continue }
            item = Item(id: id, filename: name, created: asset.creationDate ?? Date())
            Log.line("\(name): new screen recording, \(clock(asset.duration))")
        }
        guard !item.isSettled else { continue }
        // A send that keeps failing is retried less often: every pass at first, then every tenth minute.
        if item.status == .sendPending, item.attempts > 5, Date().timeIntervalSince(item.updated) < 600 { continue }
        await handle(asset, &item, dryRun: dryRun)
        if !dryRun {
            state.items[id] = item
            state.save()
        }
    }
    return 0
}

func list() -> Int32 {
    guard Library.authorize() else {
        Log.line("No access to Photos.")
        return 1
    }
    let days = Double(option("--days") ?? "30") ?? 30
    let videos = Library.videos(since: Date().addingTimeInterval(-days * 86400))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    Log.line("\(videos.count) video(s) in Photos from the last \(Int(days)) days:")
    for asset in videos {
        let name = Library.filename(of: asset)
        let mark = Library.isScreenRecording(asset, filename: name) ? "SCREEN" : "      "
        Log.line("  \(mark) \(formatter.string(from: asset.creationDate ?? Date())) \(clock(asset.duration)) \(asset.pixelWidth)x\(asset.pixelHeight) "
                 + "subtypes=\(asset.mediaSubtypes.rawValue) \(name) \(asset.localIdentifier)")
    }
    return 0
}

func process() async -> Int32 {
    guard let file = option("--file") else {
        Log.line("process needs --file")
        return 2
    }
    let source = URL(fileURLWithPath: file)
    let created = (try? FileManager.default.attributesOfItem(atPath: file)[.creationDate] as? Date) ?? Date()
    do {
        let directory = try makeDirectory(for: created)
        let movie = directory.appendingPathComponent("recording.mp4")
        if source.pathExtension.lowercased() == "mp4" {
            try FileManager.default.copyItem(at: source, to: movie)
        } else {
            try await Library.rewrap(source, as: movie)
        }
        let extract = await Writeup.extract(movie: movie, started: created)
        let decision = Judge.decide(extract)
        Writeup.write(extract, source: source.lastPathComponent, decision: decision, test: flag("--test"))
        Log.line("\(source.lastPathComponent) → \(directory.path): \(clock(extract.duration)), \(extract.wordCount) words, "
                 + "\(extract.stills.count) stills; \(decision.send ? "SEND" : "SKIP") by \(decision.by): \(decision.reason)"
                 + (decision.request.isEmpty ? "" : " | request: \(decision.request)"))
        if flag("--send") {
            Log.line("\(source.lastPathComponent): \(describe(await Dot.send(directory)))")
        }
        return 0
    } catch {
        Log.line("process failed: \(error.localizedDescription)")
        return 1
    }
}

func status() -> Int32 {
    let state = WatcherState.load()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let last = state.lastPass.map { "\(formatter.string(from: $0)) (\(Int(Date().timeIntervalSince($0))) s ago), when Photos showed it \(state.lastPassVideos ?? 0) video(s) from the last 30 days" } ?? "never"
    Log.line("Last pass: \(last); dot subscribed to Clipshot: \(Dot.hasLiveSubscription ? "yes" : "no"); "
             + "watching since \(formatter.string(from: state.since)); \(state.items.count) recording(s) seen")
    for item in state.items.values.sorted(by: { $0.created < $1.created }) {
        Log.line("  \(formatter.string(from: item.created)) \(item.status.rawValue) \(item.filename) \(item.note ?? "")")
    }
    return 0
}

let code: Int32
switch arguments.first ?? "run" {
case "run": code = await run()
case "list": code = list()
case "process": code = await process()
case "status": code = status()
default:
    Log.line("Unknown command. Use run, list, process or status.")
    code = 2
}
exit(code)
