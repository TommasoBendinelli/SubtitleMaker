import SwiftUI
import Combine
import AVFoundation    // ← for reading WAV duration


func fetchDurationSeconds(from asset: AVAsset) async throws -> Double {
    // Asynchronously load the CMTime for .duration
    let duration: CMTime = try await asset.load(.duration)
    // Convert to seconds
    return CMTimeGetSeconds(duration)
}


// MARK: - Model
struct VideoFile: Identifiable {
    let id = UUID()
    let url: URL
    var status: String = "Pending"
}

// MARK: - Processing Logic
final class Processor: ObservableObject {
    @Published var videos: [VideoFile] = []
    @Published var isProcessing = false

    private let whisperPath: String
    private let ffmpegPath: String
    private let whisperModelPath: String
    private let tempDir = FileManager.default.temporaryDirectory

    /// Compression tuning
    private let crf = "24"          // lower = better quality / larger size (default 23)
    private let preset = "slow"     // ultrafast … placebo (slower ⇢ smaller)
    private let targetHeight = 720  // output video height

    init() {
        let bundle = Bundle.main.resourceURL!
        whisperModelPath = bundle.appendingPathComponent("ggml-small.bin").path
        whisperPath = FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("whisper").path)
            ? bundle.appendingPathComponent("whisper").path : "whisper"
        ffmpegPath = FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("ffmpeg").path)
            ? bundle.appendingPathComponent("ffmpeg").path : "ffmpeg"
    }

    /// Scan folder for common video/audio extensions
    func addVideos(from folder: URL) {
        videos.removeAll()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for item in items where ["mp4","mov","mkv","avi","wav","mp3"].contains(item.pathExtension.lowercased()) {
            videos.append(VideoFile(url: item))
        }
    }

    /// Start processing without blocking UI
    func processAll() {
        guard !isProcessing else { return }
        isProcessing = true
        Task.detached { [weak self] in
            guard let self = self else { return }
            for index in self.videos.indices {
                await self.processVideo(at: index)
            }
            await MainActor.run { self.isProcessing = false }
        }
    }

    private func ffmpegEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\", ":", ",", "[", "]", "'": out.append("\\\(c)")
            case " ": out.append("\\ ")
            default: out.append(c)
            }
        }
        return out
    }

    private func runProcess(_ executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.qualityOfService = .background
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "ProcessError", code: Int(proc.terminationStatus), userInfo: nil))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    /// Convert, transcribe and subtitle one item in `videos`.
    private func processVideo(at index: Int) async {
        guard videos.indices.contains(index) else { return }
        
        // ── file info ────────────────────────────────────────────────────────────────
        let fileURL   = videos[index].url
        let ext       = fileURL.pathExtension.lowercased()
        let baseName  = fileURL.deletingPathExtension().lastPathComponent
        let srtURL    = fileURL.deletingPathExtension().appendingPathExtension("srt")

        // ── temp / output paths ──────────────────────────────────────────────────────
        let audioOnlyExts: Set<String> = ["wav", "mp3", "m4a", "flac", "aac", "ogg", "opus"]
        let isAudioOnly = audioOnlyExts.contains(ext)

        let wavURL: URL = ext == "wav"
            ? fileURL                                               // already WAV
            : tempDir.appendingPathComponent(baseName).appendingPathExtension("wav")

        let srtPrefix   = tempDir.appendingPathComponent(baseName)
        let tempSrt     = srtPrefix.appendingPathExtension("srt")

        let resFolder   = fileURL.deletingLastPathComponent().appendingPathComponent("res")
        try? FileManager.default.createDirectory(at: resFolder, withIntermediateDirectories: true)
        let outputURL   = resFolder.appendingPathComponent(baseName + "_subbed.mp4")
        
        // ── decide what needs doing ──────────────────────────────────────────────────
        let srtExists    = FileManager.default.fileExists(atPath: srtURL.path)
        let videoExists  = FileManager.default.fileExists(atPath: outputURL.path)

        if videoExists {
            await MainActor.run { videos[index].status = "Skipped (already done)" }
            return
        }
        
        // Only reach here if the final video is missing.
        // Two scenarios:
        //   • SRT missing  → we must transcribe first, then burn.
        //   • SRT exists   → skip transcription, just burn.
        
        do {
            // 1️⃣ Ensure 16 kHz mono WAV for Whisper ─ only if we will transcribe
            if !srtExists && ext != "wav" {
                await MainActor.run { videos[index].status = "Converting audio" }
                try await runProcess(ffmpegPath, arguments: [
                    "-y", "-i", fileURL.path,
                    "-ar", "16000", "-ac", "1",
                    "-c:a", "pcm_s16le",
                    wavURL.path
                ])
            }
            
            // 2️⃣ Transcribe with Whisper → .srt (only if needed)
            if !srtExists {
                await MainActor.run { videos[index].status = "Transcribing" }
                try await runProcess(whisperPath, arguments: [
                    "-m", whisperModelPath,
                    "-f", wavURL.path,
                    "-osrt", "-l", "auto",
                    "-of", srtPrefix.path
                ])
                try? FileManager.default.removeItem(at: srtURL)
                try FileManager.default.moveItem(at: tempSrt, to: srtURL)
            }
            
            // 3️⃣ Burn subtitles (always runs because we reached here with missing video)
            await MainActor.run { videos[index].status = "Burning subtitles" }
            
            let escapedSRT = ffmpegEscape(srtURL.path)
            let ffArgs: [String]
            
            if isAudioOnly {
                // — create synthetic 16:9 black canvas matching audio duration —
                let asset = AVURLAsset(url: wavURL)
                let dur = try await fetchDurationSeconds(from: asset)
                let width = Int(Double(targetHeight) * 16.0 / 9.0)
                let colorSrc = "color=size=\(width)x\(targetHeight):color=black:duration=\(dur)"
                
                ffArgs = [
                    "-y",
                    "-f", "lavfi", "-i", colorSrc,      // video
                    "-i", wavURL.path,                  // audio
                    "-vf", "subtitles='\(escapedSRT)':force_style='Fontsize=24,PrimaryColour=&H00FFFFFF'",
                    "-c:v", "libx264", "-preset", preset, "-crf", crf,
                    "-c:a", "aac", "-b:a", "128k",
                    outputURL.path
                ]
            } else {
                let vfChain = "subtitles='\(escapedSRT)',scale=-2:\(targetHeight)"
                ffArgs = [
                    "-y", "-i", fileURL.path,
                    "-vf", vfChain,
                    "-c:v", "libx264", "-preset", preset, "-crf", crf,
                    "-c:a", "aac", "-b:a", "128k",
                    outputURL.path
                ]
            }
            
            try await runProcess(ffmpegPath, arguments: ffArgs)
            await MainActor.run { videos[index].status = "Done → res/" }
            
        } catch {
            await MainActor.run { videos[index].status = "Error" }
            print("Error processing \(fileURL.lastPathComponent): \(error)")
        }
    }}

// MARK: - UI
struct ContentView: View {
    @StateObject private var processor = Processor()
    @State private var folderURL: URL?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Select Folder") { selectFolder() }
                if let folderURL { Text(folderURL.path).font(.footnote).lineLimit(1) }
                Spacer()
                Button("Process All") { processor.processAll() }
                    .disabled(processor.isProcessing || processor.videos.isEmpty)
            }
            .padding([.horizontal, .top])

            Divider()

            List(processor.videos) { video in
                HStack {
                    Text(video.url.lastPathComponent)
                    Spacer()
                    Text(video.status)
                        .foregroundColor(video.status.starts(with: "Done") ? .green : .primary)
                }
            }
            .frame(minHeight: 300)
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to access \(url.path)")
                return
            }
            folderURL = url
            processor.addVideos(from: url)
        }
    }
}
