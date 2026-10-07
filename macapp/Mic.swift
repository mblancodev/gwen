// Echo-cancelled microphone for Gwen: VoiceProcessingIO, 30 ms frames of 16 kHz mono s16le into a FIFO.
// Plain capture (`mic plain`) for a named mic or headphones. WakeSpotter listens for Hey Gwen on-device.
import AVFoundation
import AudioToolbox
import Foundation
import Speech

enum MicError: Error, CustomStringConvertible {
    case noInput, status(String, OSStatus)
    var description: String {
        switch self {
        case .noInput: return "no audio input device"
        case .status(let call, let err): return "\(call) failed (\(err))"
        }
    }
}

final class MicCapture {
    static let frameBytes = 960
    var unit: AudioUnit?
    var samples = [Int16](repeating: 0, count: 8192)  // render target, reused on the audio thread
    var pending = Data()
    let onFrame: (Data) -> Void  // called on the audio I/O thread: hand off, don't work there

    init(onFrame: @escaping (Data) -> Void) { self.onFrame = onFrame }

    func start() throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw MicError.noInput }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "AudioComponentInstanceNew")
        guard let au = u else { throw MicError.noInput }
        unit = au
        do {
            var fmt = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                  mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                  mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            // Bus 1 is the mic, bus 0 the speaker; voice processing insists both client sides use the same format.
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, size), "mic format")
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, size), "output format")
            if #available(macOS 14.0, *) {  // leave the user's music at full volume while we listen
                var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
                try check(AudioUnitSetProperty(au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global,
                                               0, &duck, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)), "ducking")
            }
            let me = Unmanaged.passUnretained(self).toOpaque()
            let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            var input = AURenderCallbackStruct(inputProc: { ref, flags, ts, bus, n, _ in
                Unmanaged<MicCapture>.fromOpaque(ref).takeUnretainedValue().render(flags, ts, bus, n)
            }, inputProcRefCon: me)
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &input, cbSize), "input callback")
            // Voice processing only runs while its output side runs too; Gwen plays nothing through it, so it gets silence.
            var silence = AURenderCallbackStruct(inputProc: { _, flags, _, _, _, list in
                for b in UnsafeMutableAudioBufferListPointer(list!) { memset(b.mData, 0, Int(b.mDataByteSize)) }
                flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                return noErr
            }, inputProcRefCon: nil)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &silence, cbSize), "output callback")
            try check(AudioUnitInitialize(au), "AudioUnitInitialize")
            try check(AudioOutputUnitStart(au), "AudioOutputUnitStart")
        } catch {
            stop()
            throw error
        }
    }

    /// Stops the unit and releases the microphone (the orange indicator goes away).
    func stop() {
        guard let au = unit else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
        pending.removeAll()
    }

    func check(_ err: OSStatus, _ call: String) throws { if err != noErr { throw MicError.status(call, err) } }

    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                _ bus: UInt32, _ n: UInt32) -> OSStatus {
        guard let au = unit, Int(n) <= samples.count else { return noErr }
        let err = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: n * 2,
                                                                                mData: raw.baseAddress))
            return AudioUnitRender(au, flags, ts, bus, n, &list)
        }
        guard err == noErr else { return err }
        samples.withUnsafeBytes { pending.append(contentsOf: $0.prefix(Int(n) * 2)) }
        while pending.count >= MicCapture.frameBytes {
            onFrame(pending.prefix(MicCapture.frameBytes))
            pending.removeFirst(MicCapture.frameBytes)
        }
        return noErr
    }
}

/// `mic on <fifo>` / `mic off` from the listener: live capture into the FIFO it created. Writes are non-blocking and
/// only whole frames are ever dropped (a write may be partial: a FIFO takes at most PIPE_BUF bytes atomically), so
/// a stalled listener costs audio, never frame alignment, and never blocks capture. A failure is reported as
/// `mic error <reason>` and the listener asks for the plain capture (`mic plain`) instead.
final class MicFifo {
    let queue = DispatchQueue(label: "gwen.mic")  // on, off and every write, in order
    var capture: MicCapture?
    var fd: Int32 = -1
    var backlog = Data()
    lazy var spotter = WakeSpotter(queue: queue)
    var tap: AVCaptureSession?
    lazy var tapFeed = TapFeed(fifo: self)

    func handle(_ arg: String) {
        if arg.hasPrefix("on ") {
            let path = String(arg.dropFirst(3))
            queue.async { self.on(path) }
        } else if arg.hasPrefix("plain ") {
            let parts = arg.dropFirst(6).split(separator: "\t", maxSplits: 1).map(String.init)
            queue.async { self.plain(parts[0], parts.count > 1 ? parts[1] : "default") }
        } else if arg == "off" {
            queue.async { self.off() }
        }
    }

    func on(_ path: String) {
        off()
        // Headphones: nothing to cancel, and voice processing would drop a headset to call quality (HUD+Mic.swift).
        if headphonesOut() { return fail("headphones: plain capture instead") }
        guard openFifo(path) else { return }
        let cap = MicCapture { [weak self] frame in self?.queue.async { self?.write(frame); self?.spotter.feed(frame) } }
        do {
            try cap.start()
            capture = cap
            spotter.start()  // Hey Gwen
        } catch {
            fail("\(error)")
        }
    }

    func write(_ frame: Data) {
        guard fd >= 0 else { return }
        if backlog.count < 32 * MicCapture.frameBytes { backlog.append(frame) }  // ~1 s behind: drop this frame
        while !backlog.isEmpty {
            let n = backlog.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { backlog.removeFirst(n); continue }
            if n < 0 && errno == EAGAIN { return }  // the listener is behind: the rest goes next time
            let why = n < 0 ? String(cString: strerror(errno)) : "wrote nothing"  // stderr: app.log
            FileHandle.standardError.write("mic: fifo write failed: \(why)\n".data(using: .utf8)!)
            return off()  // EPIPE: the listener closed its end
        }
    }

    /// The listener opens the read end as it asks for the mic; until it has, a non-blocking open says ENXIO.
    func openFifo(_ path: String) -> Bool {
        signal(SIGPIPE, SIG_IGN)  // a listener that closed its end must not kill Gwen.app: write() gets EPIPE instead
        var f: Int32 = -1
        for _ in 0..<100 {
            f = open(path, O_WRONLY | O_NONBLOCK)
            if f >= 0 || errno != ENXIO { break }
            usleep(20_000)
        }
        guard f >= 0 else { fail("open \(path): \(String(cString: strerror(errno)))"); return false }
        fd = f
        return true
    }

    /// `mic plain <fifo>\t<name>` (a mic picked by name, headphones, a call): the same frames into the FIFO with no
    /// voice processing, so nothing you're playing is ducked or filtered and a call keeps its sound. The capture
    /// output converts to 16 kHz mono s16le itself. The recognizer hears it too (the bar's words, "Hey Gwen").
    func plain(_ path: String, _ name: String) {
        off()
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio,
                                                     position: .unspecified).devices.first { $0.localizedName == name }
        guard let mic = found ?? AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic) else {
            return fail("no audio input device")
        }
        let session = AVCaptureSession(), out = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(out) else { return fail("can't capture from \(mic.localizedName)") }
        guard openFifo(path) else { return }
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                             AVLinearPCMIsNonInterleaved: false]
        session.addInput(input)
        session.addOutput(out)
        out.setSampleBufferDelegate(tapFeed, queue: queue)
        session.startRunning()
        tap = session
        spotter.start()
    }

    func off() {
        spotter.stop()
        tap?.stopRunning()
        tap = nil
        tapFeed.pending.removeAll()
        capture?.stop()
        capture = nil
        if fd >= 0 { close(fd) }
        fd = -1
        backlog.removeAll()
    }

    func fail(_ reason: String) {
        off()
        DispatchQueue.main.async { emit("mic error " + reason) }
    }
}

/// The plain capture's buffers (already 16 kHz mono s16le), cut into the 30 ms frames the listener reads. On MicFifo's queue.
final class TapFeed: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    unowned let fifo: MicFifo
    var pending = Data()
    init(fifo: MicFifo) { self.fifo = fifo }
    func captureOutput(_ output: AVCaptureOutput, didOutput buf: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(buf) else { return }
        let n = CMBlockBufferGetDataLength(block)
        var chunk = Data(count: n)
        guard n > 0, chunk.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }) == noErr
        else { return }
        pending.append(chunk)
        while pending.count >= MicCapture.frameBytes {
            let frame = Data(pending.prefix(MicCapture.frameBytes))
            pending.removeFirst(MicCapture.frameBytes)
            fifo.write(frame)
            fifo.spotter.feed(frame)
        }
    }
}

/// Apple's on-device speech recognizer as a cheap wake-word spotter. Emits `heard <task> <partial transcript>`; the
/// listener matches the wake word there, its trained spellings too (Wake.swift). `wake on` / `wake off`: off (the
/// Settings switch, speech recognition denied, no on-device model) means the listener ignores what was heard.
/// Runs on MicFifo's queue.
final class WakeSpotter {
    static let wakeLocaleId = "en-US"  // "Hey Gwen" stay English-spotted
    let queue: DispatchQueue
    var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: WakeSpotter.wakeLocaleId))
    var localeId = WakeSpotter.wakeLocaleId
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var id = 0
    var started = Date()
    var wanted = false
    var onHeard: ((Int, String) -> Void)?  // on the main thread

    init(queue: DispatchQueue) { self.queue = queue }

    /// Keyboard language, else this Mac's preferred languages, if on-device recognition has them; else en-US.
    static func liveLocaleId() -> String {
        var ids: [String] = []
        if let k = keyboardLanguage() { ids.append(k) }
        ids.append(contentsOf: Locale.preferredLanguages)
        let supported = SFSpeechRecognizer.supportedLocales()
        for id in ids {
            let exact = Locale(identifier: id)
            if let r = SFSpeechRecognizer(locale: exact), r.supportsOnDeviceRecognition { return r.locale.identifier }
            let lang = Locale.Language(identifier: id).languageCode?.identifier
            if let lang, let match = supported.first(where: { $0.language.languageCode?.identifier == lang }),
               let r = SFSpeechRecognizer(locale: match), r.supportsOnDeviceRecognition {
                return match.identifier
            }
        }
        return wakeLocaleId
    }

    /// Swap the recognizer's language. Caller restarts when a fresh task is needed; wake locale restores itself.
    @discardableResult
    func setLocale(_ id: String) -> Bool {
        guard id != localeId || recognizer == nil else { return false }
        localeId = id
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: id))
        return true
    }

    func useWakeLocale() {
        if setLocale(Self.wakeLocaleId), wanted { restart() }
    }

    func useLiveLocale() { setLocale(Self.liveLocaleId()) }

    func start() {
        wanted = true
        setLocale(Self.wakeLocaleId)  // wake locale; restart only after auth below
        SFSpeechRecognizer.requestAuthorization { status in
            self.queue.async {
                guard self.wanted else { return }
                guard status == .authorized, let r = self.recognizer, r.supportsOnDeviceRecognition else {
                    DispatchQueue.main.async { emit("wake off") }
                    return
                }
                self.restart()
                DispatchQueue.main.async {
                    emit(GwenConfig.bool("wake") ? "wake on" : "wake off")
                    WakeTrainer.firstRun()
                }
            }
        }
    }

        func restart() {
        task?.cancel()
        request?.endAudio()
        id += 1
        started = Date()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true  // the audio never leaves this Mac
        req.shouldReportPartialResults = true
        req.contextualStrings = ["Gwen", "Hey Gwen"]  // names it would else write as words it knows ("when", "Glen")
        request = req
        let mine = id
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                DispatchQueue.main.async {
                    let line = text.replacingOccurrences(of: "\n", with: " ")
                    emit("heard \(mine) " + line)
                    self?.onHeard?(mine, line)  // the bar shows it while you talk (HUD+Live.swift)
                }
            }
            guard error != nil || result?.isFinal == true else { return }
            // A task ends on its own (silence, a final result, an error): a new one, after a beat so an error can't spin.
            self?.queue.asyncAfter(deadline: .now() + 1) {
                guard let self = self, self.wanted, self.id == mine else { return }
                self.restart()
            }
        }
    }

    func feed(_ frame: Data) {
        guard let req = request else { return }
        if Date().timeIntervalSince(started) > 50 { return restart() }  // keep each transcript (and task) short
        let n = frame.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        frame.withUnsafeBytes { raw in
            for i in 0..<n { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))) / 32768 }
        }
        req.append(buf)
    }

    func stop() {
        wanted = false
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
    }
}

let micFifo = MicFifo()

/// On a call: another app has a microphone open (Zoom, Teams, FaceTime, Slack, Meet in a browser). Gwen's own
/// capture and Apple's daemons (Siri listens all the time) don't count; FaceTime and Safari's
/// WebKit do.
// ponytail: bundle-id rules, not a list of call apps; a dictation app holding the mic counts as a call too
func otherAppUsesMic() -> Bool {
    guard #available(macOS 14.2, *) else { return false }
    return otherApp(running: kAudioProcessPropertyIsRunningInput) {
        !$0.hasPrefix("com.apple.") || $0 == "com.apple.FaceTime" || $0.hasPrefix("com.apple.WebKit")
    }
}

/// Playing: another app's audio output is running (a video, music). The echo canceller doesn't catch it all (other
/// speakers, a monitor's), and lyrics then wake Gwen. Gwen's own sounds (afplay, no bundle id) don't count.
func otherAppPlays() -> Bool {
    guard #available(macOS 14.2, *) else { return false }
    return otherApp(running: kAudioProcessPropertyIsRunningOutput) {
        !$0.hasPrefix("com.apple.") || $0.hasPrefix("com.apple.WebKit")
            || ["com.apple.Music", "com.apple.TV", "com.apple.podcasts", "com.apple.QuickTimePlayerX"].contains($0)
    }
}

/// CoreAudio's per-process list (macOS 14.2+): does another app (not Gwen, not bundle-less) have `selector` running?
@available(macOS 14.2, *)
func otherApp(running selector: AudioObjectPropertySelector, _ counts: (String) -> Bool) -> Bool {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return false }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }
    return ids.contains { id in
        var a = AudioObjectPropertyAddress(mSelector: selector,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var n = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &running) == noErr, running != 0 else { return false }
        a.mSelector = kAudioProcessPropertyBundleID
        var bundle: Unmanaged<CFString>?
        n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &bundle) == noErr,
              let b = bundle?.takeRetainedValue() as String?, !b.isEmpty, b != "app.gwen.hud" else { return false }
        return counts(b)
    }
}
