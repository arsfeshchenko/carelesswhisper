import AppKit

enum SoundPlayer {
    static func play(_ name: String) {
        guard Settings.soundsEnabled else { return }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.1
        sound.play()
    }
}
