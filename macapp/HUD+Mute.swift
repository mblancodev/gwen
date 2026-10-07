// "Mute other audio while listening" (Settings ▸ Dictation, on by default): while Gwen is dictating and
// another app is playing, the default output is muted, so a video doesn't talk over you or into the transcript.
// Unmuted as soon as it stops listening, and only if Gwen muted it.
import AppKit
import CoreAudio

extension HUD {
    static var mutedByGwen = false
    static var chimeUntil = Date.distantPast
    static var muteWhileListening: Bool {
        get { UserDefaults.standard.object(forKey: "muteWhileListening") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "muteWhileListening") }
    }

    /// Called on every state change (apply) and when the setting flips.
    /// "Hey Gwen" landed. Muting other audio waits for it, or the dictation it starts would cut it off.
    func wakeChime() {
        NSSound(named: "Tink")?.play()
        HUD.chimeUntil = Date().addingTimeInterval(0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.updateMute() }
    }

    func updateMute() {
        let want = HUD.muteWhileListening && state == "dictating" && Date() >= HUD.chimeUntil
            && (HUD.mutedByGwen || otherAppPlays())
        if want && !HUD.mutedByGwen {
            if outputMuted() == false, setOutputMuted(true) { HUD.mutedByGwen = true }
        } else if !want {
            restoreSound()
        }
    }

    /// Gwen going away for any reason (Quit, the listener closing its pipe, SIGTERM) never leaves their sound off.
    static func restoreSoundOnExit() {
        atexit { restoreSound() }
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { exit(0) }
        term.resume()
        termSource = term
    }
}

private var termSource: DispatchSourceSignal?

func restoreSound() {
    guard HUD.mutedByGwen else { return }
    _ = setOutputMuted(false)
    HUD.mutedByGwen = false
}

/// The default output device's mute: nil when it has none (some HDMI / DisplayPort monitors).
// ponytail: a device without a mute switch isn't muted; lower its volume instead if someone needs that.
func outputMuted() -> Bool? {
    guard let dev = defaultOutput() else { return nil }
    var addr = muteAddress()
    var v: UInt32 = 0
    var n = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &n, &v) == noErr else { return nil }
    return v != 0
}

func setOutputMuted(_ on: Bool) -> Bool {
    guard let dev = defaultOutput() else { return false }
    var addr = muteAddress()
    var v: UInt32 = on ? 1 : 0
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
}

private func muteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain)
}

private func defaultOutput() -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    var n = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &n, &dev) == noErr, dev != 0
    else { return nil }
    return dev
}
