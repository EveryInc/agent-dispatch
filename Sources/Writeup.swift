// Turns a movie file into a Clipshot-format recording folder: stills with the text on screen, a timed
// transcript, session.json and notes.md. The method follows Clipshot's Session.swift so the dot reads an iPhone
// recording exactly as it reads a Mac one. Everything here runs on this Mac.
import AppKit
import AVFoundation
import Speech
import Vision

struct Segment {
    var start: Double
    var end: Double
    var text: String
}

struct Still {
    var time: Double
    var reason: String
    var file = ""
    var textFile: String?
    var segments: [Segment] = []
}

/// What was pulled out of a recording, before anything is decided about it.
struct Extract {
    var directory: URL
    var started: Date
    var duration: Double
    var size: CGSize
    var stills: [Still]
    var segments: [Segment]
    var hasAudio: Bool
    var problems: [String]

    var transcript: String { segments.map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n") }
    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }

    /// The text on screen in the first few stills, for the judge.
    func screenText(limit: Int = 4000) -> String {
        var text = ""
        for still in stills.prefix(6) {
            guard let file = still.textFile,
                  let content = try? String(contentsOf: directory.appendingPathComponent("frames/\(file)"), encoding: .utf8) else { continue }
            text += "--- screen at \(clock(still.time)) ---\n\(content.prefix(900))\n"
            if text.count > limit { break }
        }
        return String(text.prefix(limit))
    }
}

enum Writeup {
    static let schema = "clipshot-recording/1"

    static func extract(movie: URL, started: Date) async -> Extract {
        let directory = movie.deletingLastPathComponent()
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.removeItem(at: framesDirectory)
        try? FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        var problems: [String] = []

        let asset = AVURLAsset(url: movie)
        var duration = 0.0
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 { duration = seconds }
        var size = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let turned = natural.applying(transform)
            size = CGSize(width: abs(turned.width), height: abs(turned.height))
        }

        var stills = await pickStills(from: asset, duration: duration)
        stills = await writeStills(stills, from: asset, to: framesDirectory)
        if stills.isEmpty { problems.append("No stills could be taken from the recording.") }

        var segments: [Segment] = []
        let audio = directory.appendingPathComponent("audio.m4a")
        let hasAudio = await exportAudio(from: movie, to: audio)
        if hasAudio {
            do {
                segments = try await transcribe(audio, hints: hints(from: stills, in: framesDirectory))
            } catch {
                problems.append("Transcription failed: \(error.localizedDescription)")
            }
            if segments.isEmpty, problems.isEmpty { problems.append("No speech was detected.") }
        } else {
            problems.append("The recording has no sound. (On iPhone, long-press the record button in Control Center and turn the microphone on.)")
        }

        stills = attach(segments, to: stills, duration: duration)
        // Drop stills that attach() let go of.
        let kept = Set(stills.flatMap { [$0.file, $0.textFile ?? ""] })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: framesDirectory.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: framesDirectory.appendingPathComponent(name))
        }
        return Extract(directory: directory, started: started, duration: duration, size: size, stills: stills, segments: segments,
                       hasAudio: hasAudio, problems: problems)
    }

    // MARK: Stills

    /// The start, then every time the screen changes substantially (a new page, a scroll, a new answer).
    private static func pickStills(from asset: AVAsset, duration: Double) async -> [Still] {
        guard duration > 0 else { return [] }
        var stills = [Still(time: min(0.4, duration / 2), reason: "start")]
        let sampler = AVAssetImageGenerator(asset: asset)
        sampler.appliesPreferredTrackTransform = true
        sampler.maximumSize = CGSize(width: 128, height: 128)
        sampler.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        sampler.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        var reference: [UInt8]?
        var lastKept = 0.0
        var time = 1.0
        while time < duration {
            if let image = try? await sampler.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
               let gray = grayscale(image, width: 36, height: 64) {
                if let previous = reference {
                    if changedFraction(previous, gray) > 0.12, time - lastKept >= 4 {
                        stills.append(Still(time: min(time + 0.3, duration - 0.05), reason: "screen changed"))
                        reference = gray
                        lastKept = time
                    }
                } else {
                    reference = gray
                }
            }
            time += 1
        }
        return stills
    }

    private static func writeStills(_ stills: [Still], from asset: AVAsset, to directory: URL) async -> [Still] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2560, height: 2560)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        var written: [Still] = []
        for still in stills {
            guard let image = try? await generator.image(at: CMTime(seconds: still.time, preferredTimescale: 600)).image else { continue }
            var still = still
            let stem = String(format: "%04d-%@", written.count + 1, clock(still.time).replacingOccurrences(of: ":", with: "m") + "s")
            still.file = stem + ".jpg"
            guard writeJPEG(image, to: directory.appendingPathComponent(still.file)) else { continue }
            let lines = readText(in: image)
            if !lines.isEmpty {
                still.textFile = stem + ".txt"
                try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent(stem + ".txt"), atomically: true, encoding: .utf8)
            }
            written.append(still)
        }
        return written
    }

    private static func readText(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Interface text is full of names and codes a dictionary would "correct" into something else.
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Capitalised words on screen, which is where names of people, models and products show up.
    private static func hints(from stills: [Still], in directory: URL) -> [String] {
        var counts: [String: Int] = [:]
        var text = ""
        for still in stills.prefix(12) {
            guard let file = still.textFile, let content = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else { continue }
            text += "\n" + content
        }
        for word in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            guard candidate.count >= 3, candidate.count <= 24, let first = candidate.first,
                  first.isUppercase || candidate.contains(where: \.isNumber) else { continue }
            counts[candidate, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(100).map(\.key)
    }

    /// Files each remark under the still that was showing when it began, then drops screen changes nobody
    /// spoke over that were replaced within a few seconds (mid-scroll, mid-load).
    private static func attach(_ segments: [Segment], to stills: [Still], duration: Double) -> [Still] {
        guard !stills.isEmpty else { return [] }
        var stills = stills
        for segment in segments {
            let index = stills.lastIndex { $0.time <= segment.start + 0.4 } ?? 0
            stills[index].segments.append(segment)
        }
        var kept: [Still] = []
        for (index, still) in stills.enumerated() {
            let shownFor = (index + 1 < stills.count ? stills[index + 1].time : duration) - still.time
            if still.reason == "screen changed", still.segments.isEmpty, shownFor < 3 { continue }
            kept.append(still)
        }
        return kept
    }

    // MARK: Words

    /// Transcribes speech on-device, with timings.
    private static func transcribe(_ audio: URL, hints: [String]) async throws -> [Segment] {
        let supported = await SpeechTranscriber.supportedLocales
        let locale = supported.first { $0.identifier(.bcp47) == Locale.current.identifier(.bcp47) } ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // First use of a language downloads its model; after that this is a no-op.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try? await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: audio)
        async let collected: [Segment] = {
            var segments: [Segment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var start: Double?, end = 0.0
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    if start == nil { start = range.start.seconds }
                    end = range.end.seconds
                }
                segments.append(Segment(start: start ?? end, end: end, text: text))
            }
            return segments
        }()
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected.sorted { $0.start < $1.start }
    }

    private static func exportAudio(from movie: URL, to audio: URL) async -> Bool {
        let asset = AVURLAsset(url: movie)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return false }
        try? FileManager.default.removeItem(at: audio)
        do {
            try await export.export(to: audio, as: .m4a)
            return true
        } catch {
            return false
        }
    }

    // MARK: Writing it up

    /// Writes session.json, transcript.json and notes.md. `decision` puts what the owner seems to be asking at the
    /// top of the timeline, which is the part of the notes that travels in the event to the dot.
    static func write(_ extract: Extract, source: String, decision: Decision?, test: Bool) {
        let directory = extract.directory
        var files = ["notes.md", "session.json", "recording.mp4"]
        if extract.hasAudio { files.append("audio.m4a") }
        if !extract.segments.isEmpty {
            files.append("transcript.json")
            write(json: extract.segments.map { ["start": round($0.start * 100) / 100, "end": round($0.end * 100) / 100, "text": $0.text] },
                  to: directory.appendingPathComponent("transcript.json"))
        }
        if !extract.stills.isEmpty { files.append("frames/") }

        let manifest: [String: Any] = [
            "schema": schema,
            "id": directory.lastPathComponent,
            "recorded_with": "iPhone screen recording, brought in from Photos by PhoneRecordings",
            "recorded_by": NSFullUserName(),
            "source": ["device": "iPhone", "photos_filename": source] as [String: Any],
            "started_at": ISO8601DateFormatter().string(from: extract.started),
            "duration_seconds": round(extract.duration * 10) / 10,
            "screen": ["file": "recording.mp4", "width": Int(extract.size.width), "height": Int(extract.size.height)] as [String: Any],
            "camera": NSNull(),
            "microphone": extract.hasAudio ? "iPhone" : NSNull(),
            "transcript": ["engine": "Apple SpeechTranscriber, on-device", "segments": extract.segments.count] as [String: Any],
            "apps": [["time": 0, "app": "iPhone", "window": ""] as [String: Any]],
            "frames": extract.stills.map { still -> [String: Any] in
                ["file": "frames/\(still.file)", "time": round(still.time * 10) / 10, "why": still.reason, "app": "iPhone", "window": "",
                 "screen_text": still.textFile.map { "frames/\($0)" } ?? NSNull()]
            },
            "request": decision.map { ["wants_action": $0.send, "summary": $0.request, "reason": $0.reason, "judged_by": $0.by] as [String: Any] } ?? NSNull(),
            "files_present": files,
            "problems": extract.problems,
        ]
        write(json: manifest, to: directory.appendingPathComponent("session.json"))
        try? notes(for: extract, files: files, decision: decision, test: test)
            .write(to: directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }

    private static func notes(for extract: Extract, files: [String], decision: Decision?, test: Bool) -> String {
        let name = NSFullUserName()
        let first = name.split(separator: " ").first.map(String.init) ?? name
        var lines: [String] = []
        lines.append("# iPhone screen recording — \(heading(for: extract.started))")
        lines.append("")
        lines.append("\(name) recorded their iPhone's screen while talking over it. This file is the written-up version: what was said, when, next to what was on screen. Made on their Mac from the recording in Photos.")
        lines.append("")
        lines.append("- **Length:** \(spoken(extract.duration))")
        lines.append("- **Recorded on:** iPhone")
        lines.append("- **Files here:** " + files.filter { $0 != "notes.md" }.map { "`\($0)`" }.joined(separator: ", "))
        for problem in extract.problems { lines.append("- **Note:** \(problem)") }
        lines.append("")
        lines.append("## How to read this")
        lines.append("")
        lines.append("The timeline below is in order. Each entry is a still of the phone's screen at that moment and what was said while it was showing. Times are minutes:seconds from the start of `recording.mp4`, which has everything, including the sound and what happened between the stills.")
        lines.append("")
        lines.append("The transcript was made on the Mac and can mishear names, product names and jargon. Where a word looks wrong, trust the still (each has a `.txt` beside it with the text that was on screen) or listen to the recording.")
        lines.append("")
        lines.append("## Timeline")
        lines.append("")
        // These lines are the first thing in the event the dot receives.
        if test {
            lines.append("**This is a test of the iPhone recording watcher.** Nothing in it needs doing. If you are \(first)'s dot, reply in the chat that the test recording arrived and say in one line what it shows.")
        } else {
            lines.append("**This came from \(first)'s iPhone.** They recorded their phone's screen and talked over it to ask an agent to do something about what they were looking at. Watch the recording and listen to what they say (get_recording gives a download link for the video with its sound; the stills and transcript here are a quick read of it), then do what they ask. If it is not clear what they want, ask them.")
            if let decision, !decision.request.isEmpty {
                lines.append("")
                lines.append("What they seem to be asking, as read from the transcript by a machine (the recording is the authority): \(decision.request)")
            }
        }

        if extract.stills.isEmpty {
            lines.append("")
            for segment in extract.segments { lines.append("- [\(clock(segment.start))] \(segment.text)") }
            if extract.segments.isEmpty { lines.append("Nothing could be extracted from this recording.") }
        }
        for still in extract.stills {
            lines.append("")
            lines.append("### \(clock(still.time)) · iPhone")
            lines.append("")
            lines.append("![Screen at \(clock(still.time))](frames/\(still.file))")
            lines.append("")
            if still.segments.isEmpty {
                lines.append("*(nothing said)*")
            } else {
                for segment in still.segments { lines.append("- [\(clock(segment.start))] \(segment.text)") }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func spoken(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) seconds" }
        return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s"
    }

    private static func heading(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    private static func write(json: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 24 { changed += 1 }
        return Double(changed) / Double(a.count)
    }
}
