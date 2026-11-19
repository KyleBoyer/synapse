import AVFoundation
import AudioToolbox
import CoreAudio

/// Reads one microphone through an input-only Core Audio HAL unit, converted to 24 kHz mono Int16.
/// AVCaptureSession was used before; its CoreMediaIO layer crashed the app (EXC_BAD_ACCESS in CMIOBaseUnits) when a
/// Bluetooth headset's mic was switched off mid-session. The HAL unit has no such layer, and `onLost` reports the
/// device going away so the caller can end the session.
final class HALInput: @unchecked Sendable {
    private var unit: AudioUnit?
    private let device: AudioDeviceID
    private let deliver: @Sendable ([Int16]) -> Void
    private let converter: AVAudioConverter
    private let hwFormat: AVAudioFormat
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private let scratch: AVAudioPCMBuffer
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private let lost: @Sendable () -> Void

    /// `uid` "" is the system default input.
    init(uid: String, deliver: @escaping @Sendable ([Int16]) -> Void, lost: @escaping @Sendable () -> Void) throws {
        guard let id = uid.isEmpty ? Self.defaultInput() : AudioDevices.device(uid: uid, input: true) else {
            throw Self.error("The microphone is not connected.")
        }
        device = id; self.deliver = deliver; self.lost = lost
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw Self.error("No audio input unit.") }
        var u: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &u), "open the input unit")
        guard let u else { throw Self.error("No audio input unit.") }
        unit = u
        var on: UInt32 = 1, off: UInt32 = 0, dev = id
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable input")
        try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable output")
        try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                            UInt32(MemoryLayout<AudioDeviceID>.size)), "select the microphone")
        // The unit converts channels but not sample rate on the input side, so read mono Float at the device's rate.
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "read the mic format")
        guard hw.mSampleRate > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: format, to: target),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw Self.error("Unsupported microphone format.") }
        hwFormat = format; converter = conv; scratch = buf
        var client = format.streamDescription.pointee
        try Self.check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set the read format")
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, bus, frames, _ in
            Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue().read(flags, time, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                            UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set the input callback")
        try Self.check(AudioUnitInitialize(u), "start the microphone")
        watchAlive()
        do { try Self.check(AudioOutputUnitStart(u), "start the microphone") } catch { stop(); throw error }
    }

    private func read(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                      _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, frames <= scratch.frameCapacity else { return noErr }
        scratch.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, bus, frames, scratch.mutableAudioBufferList)
        guard status == noErr else { return status }
        let cap = AVAudioFrameCount(Double(frames) * 24000 / hwFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return noErr }
        var fed = false
        var err: NSError?
        let input = scratch
        converter.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true; s.pointee = .haveData; return input
        }
        if err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] {
            deliver(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength))))
        }
        return noErr
    }

    /// Reports the device dying (unplugged, switched off, a Bluetooth headset disconnecting).
    private func watchAlive() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let device = device, lost = lost
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            var alive: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &alive) != noErr || alive == 0 { lost() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr { aliveListener = block }
    }

    func stop() {
        if let block = aliveListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
            aliveListener = nil
        }
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return s == noErr && id != 0 ? id : nil
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw error("Could not \(what) (\(status)).")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Synapse", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
