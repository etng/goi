import AVFoundation
import Foundation

final class AudioPlayer {
    static let shared = AudioPlayer()
    private var player: AVAudioPlayer?

    /// Returns false when the data is in a format AVFoundation can't decode
    /// (e.g. Speex .spx used by some pronunciation dictionaries).
    func play(_ data: Data) -> Bool {
        do {
            let player = try AVAudioPlayer(data: data)
            self.player = player
            player.play()
            return true
        } catch {
            return false
        }
    }
}
