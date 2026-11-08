import AVFoundation
import Foundation

/// v0.26 (PORT-23): plays ElevenLabs' MP3 for Read aloud. `play` throws when
/// the data isn't audio this Mac can play (an HTML error page, an empty body),
/// so Read aloud falls back to the Mac voice with a note, never silence.
@MainActor
protocol AudioPlaying: AnyObject {
    /// Called with the token when that audio ends by itself.
    var onFinish: ((Int) -> Void)? { get set }
    func play(_ mp3: Data, token: Int) throws
    func stop()
}

enum AudioPlaybackError: Error {
    case unplayable
}

@MainActor
final class SystemAudioPlayer: NSObject, AudioPlaying, AVAudioPlayerDelegate {
    var onFinish: ((Int) -> Void)?
    private var player: AVAudioPlayer?
    private var token = 0

    func play(_ mp3: Data, token: Int) throws {
        stop()
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: mp3, fileTypeHint: AVFileType.mp3.rawValue)
        } catch {
            throw AudioPlaybackError.unplayable
        }
        player.delegate = self
        guard player.play() else { throw AudioPlaybackError.unplayable }
        self.player = player
        self.token = token
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        MainActor.assumeIsolated {
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.player = nil
            self.onFinish?(self.token)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
