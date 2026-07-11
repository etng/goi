import AVFoundation
import Foundation

final class AudioPlayer {
    static let shared = AudioPlayer()
    private var player: AVAudioPlayer?

    enum PlayResult {
        case played
        case unsupported(ext: String)   // format needs an external decoder we don't have
        case failed
    }

    /// External decoder for formats AVFoundation can't read (Ogg Speex .spx,
    /// Ogg Vorbis). Detected at runtime like mecab; absent → we report it.
    static var decoderPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
         "/opt/homebrew/bin/speexdec", "/usr/local/bin/speexdec"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var decoderInstallHint: String { "brew install ffmpeg" }

    func play(_ data: Data, ext: String) -> PlayResult {
        if let player = try? AVAudioPlayer(data: data) {
            self.player = player
            player.play()
            return .played
        }
        // AVFoundation can't decode it — try an external decoder to WAV
        if let wav = Self.decodeToWav(data, ext: ext), let player = try? AVAudioPlayer(data: wav) {
            self.player = player
            player.play()
            return .played
        }
        return Self.decoderPath == nil ? .unsupported(ext: ext) : .failed
    }

    /// Decodes via ffmpeg/speexdec into WAV bytes. Returns nil if no decoder
    /// or the conversion fails.
    private static func decodeToWav(_ data: Data, ext: String) -> Data? {
        guard let decoder = decoderPath else { return nil }
        let tmp = FileManager.default.temporaryDirectory
        let input = tmp.appendingPathComponent("goi-audio-in.\(ext.isEmpty ? "bin" : ext)")
        let output = tmp.appendingPathComponent("goi-audio-out.wav")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        guard (try? data.write(to: input)) != nil else { return nil }
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: decoder)
        if decoder.hasSuffix("ffmpeg") {
            process.arguments = ["-y", "-loglevel", "quiet", "-i", input.path, output.path]
        } else { // speexdec input.spx output.wav
            process.arguments = [input.path, output.path]
        }
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return try? Data(contentsOf: output)
    }
}
