import AudioToolbox
import CoreAudio
import Foundation

public class AudioRecorder {
  private var deviceID: AudioObjectID
  private var ioProcID: AudioDeviceIOProcID?
  private var finalFormat: AudioStreamBasicDescription!
  private var audioBuffer: AudioBuffer?
  private var outputHandler: AudioOutputHandler
  private var converter: AudioFormatConverter?

  /// Dual mode: the aggregate carries a mic sub-device + the system tap, which
  /// the IOProc delivers as separate buffers in one (co-clocked) callback. We
  /// interleave them into stereo [L=mic, R=system] ourselves instead of using
  /// the single-stream ring-buffer path.
  private let dualMode: Bool
  private var loggedDualLayout = false
  private var interleaveScratch: UnsafeMutablePointer<Float>?
  private var interleaveScratchFrames = 0
  // Frame-lock diagnostics: if mic and tap deliver equal frame counts every
  // callback, the two streams cannot accumulate a relative offset (no drift).
  private var dbgMicFrames = 0
  private var dbgTapFrames = 0
  private var dbgCallbacks = 0
  private var dbgMismatchCallbacks = 0

  /// The audio format this recorder produces (after any conversion).
  public var outputFormat: AudioStreamBasicDescription {
    return finalFormat
  }

  /// Whether this recorder is performing sample rate conversion.
  public var isConverting: Bool {
    return converter != nil
  }

  public init(
    deviceID: AudioObjectID, outputHandler: AudioOutputHandler, convertToSampleRate: Double? = nil,
    chunkDuration: Double = 0.2, dualMode: Bool = false
  ) throws {
    self.deviceID = deviceID
    self.outputHandler = outputHandler
    self.dualMode = dualMode

    // Get source format and set up conversion if requested
    let sourceFormat = try AudioFormatManager.getDeviceFormat(deviceID: deviceID)

    // Dual mode produces a fixed interleaved stereo float stream at the
    // aggregate's (master = mic) sample rate. No ring buffer, no SRC.
    if dualMode {
      if convertToSampleRate != nil {
        AudioTeeLogging.logger.error(
          "Sample-rate conversion is not supported in dual (mic+system) mode; ignoring")
      }
      var fmt = AudioStreamBasicDescription()
      fmt.mSampleRate = sourceFormat.mSampleRate
      fmt.mFormatID = kAudioFormatLinearPCM
      fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
      fmt.mBitsPerChannel = 32
      fmt.mChannelsPerFrame = 2
      fmt.mFramesPerPacket = 1
      fmt.mBytesPerFrame = 8
      fmt.mBytesPerPacket = 8
      self.converter = nil
      self.audioBuffer = nil
      self.finalFormat = fmt
      return
    }

    // Set up the audio buffer using source format and configurable chunk duration
    self.audioBuffer = AudioBuffer(format: sourceFormat, chunkDuration: chunkDuration)

    if let targetSampleRate = convertToSampleRate {
      // Validate sample rate
      guard AudioFormatConverter.isValidSampleRate(targetSampleRate) else {
        AudioTeeLogging.logger.error(
          "Invalid sample rate", context: ["sample_rate": String(targetSampleRate)])
        self.converter = nil
        self.finalFormat = sourceFormat
        return
      }

      do {
        let converter = try AudioFormatConverter.toSampleRate(targetSampleRate, from: sourceFormat)
        self.converter = converter
        self.finalFormat = converter.targetFormatDescription
        AudioTeeLogging.logger.info(
          "Audio conversion enabled", context: ["target_sample_rate": String(targetSampleRate)])
      } catch {
        AudioTeeLogging.logger.error(
          "Failed to create audio converter, using original format",
          context: ["error": String(describing: error)])
        self.converter = nil
        self.finalFormat = sourceFormat
      }
    } else {
      self.converter = nil
      self.finalFormat = sourceFormat
    }
  }

  public func startRecording() throws {
    AudioTeeLogging.logger.debug("Starting audio recording")

    if dualMode { logInputStreamConfig() }

    // Log format info and send metadata for final format
    AudioFormatManager.logFormatInfo(finalFormat)
    let metadata = AudioFormatManager.createMetadata(for: finalFormat)
    outputHandler.handleMetadata(metadata)
    outputHandler.handleStreamStart()

    try setupAndStartIOProc()

    AudioTeeLogging.logger.info("Audio device started successfully")
  }

  // Note to self, what about installTap? Would require audio engine and a node?
  // No; AudioEngine.installTap() can only fire as often as 100ms. too slow for us
  private func setupAndStartIOProc() throws {
    AudioTeeLogging.logger.debug("Creating IO proc")
    var status = AudioDeviceCreateIOProcID(
      deviceID,
      {
        (inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData)
          -> OSStatus in
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(inClientData!).takeUnretainedValue()
        return recorder.processAudio(inInputData)
      },
      Unmanaged.passUnretained(self).toOpaque(),
      &ioProcID
    )

    guard status == noErr else {
      throw AudioTeeError.ioProcCreationFailed(status)
    }

    AudioTeeLogging.logger.debug("Starting audio device")
    status = AudioDeviceStart(deviceID, ioProcID)

    if status != noErr {
      cleanupIOProc()
      throw AudioTeeError.deviceStartFailed(status)
    }
  }

  private func processAudio(_ inputData: UnsafePointer<AudioBufferList>) -> OSStatus {
    if dualMode {
      return processAudioDual(inputData)
    }

    let bufferList = inputData.pointee
    let firstBuffer = bufferList.mBuffers

    guard let sourcePointer = firstBuffer.mData, firstBuffer.mDataByteSize > 0 else {
      AudioTeeLogging.logger.error("Received empty audio buffer")
      return noErr
    }

    // Copy directly from the Core Audio buffer into our ring buffer.
    // This avoids creating an intermediate Data object (heap alloc + memcpy)
    // on every IO callback (~10ms). The pointer is valid for the duration
    // of this callback, so this is safe.
    audioBuffer?.append(from: sourcePointer, count: Int(firstBuffer.mDataByteSize))

    processAudioBuffer()

    return noErr
  }

  /// Interleave the aggregate's mic + tap buffers into stereo [L=mic, R=system].
  ///
  /// The two source streams arrive in the same callback (one aggregate clock),
  /// so frame N of the mic lines up with frame N of the tap. Mic is expected
  /// mono (1ch); the tap is captured stereo (2ch) and downmixed to mono for R,
  /// which also lets us tell the buffers apart by channel count regardless of
  /// their order in the list.
  private func processAudioDual(_ inputData: UnsafePointer<AudioBufferList>) -> OSStatus {
    let abl = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: inputData))

    // NB: `CoreAudio.AudioBuffer` is the Core Audio struct; this module also
    // defines a class named `AudioBuffer` (the ring buffer), hence the qualifier.
    var micBuf: CoreAudio.AudioBuffer?
    var tapBuf: CoreAudio.AudioBuffer?
    for buf in abl {
      guard buf.mData != nil, buf.mDataByteSize > 0 else { continue }
      if buf.mNumberChannels >= 2 && tapBuf == nil {
        tapBuf = buf
      } else if buf.mNumberChannels == 1 && micBuf == nil {
        micBuf = buf
      }
    }

    // Fallback: if channel counts didn't disambiguate (e.g. a mono tap or a
    // multichannel mic), take the first two non-empty buffers in list order
    // and assume [mic, tap]. Logged loudly so the smoke test flags it.
    if micBuf == nil || tapBuf == nil {
      let nonEmpty = abl.filter { $0.mData != nil && $0.mDataByteSize > 0 }
      if nonEmpty.count >= 2 {
        micBuf = nonEmpty[0]
        tapBuf = nonEmpty[1]
      }
    }

    if !loggedDualLayout {
      loggedDualLayout = true
      var parts: [String] = []
      for (i, buf) in abl.enumerated() {
        parts.append("buf\(i)[ch=\(buf.mNumberChannels),bytes=\(buf.mDataByteSize)]")
      }
      AudioTeeLogging.logger.info(
        "Dual IOProc buffer layout",
        context: [
          "buffers": String(abl.count),
          "detail": parts.joined(separator: " "),
          "mic_found": String(micBuf != nil),
          "tap_found": String(tapBuf != nil),
          "sample_rate": String(Int(finalFormat.mSampleRate)),
        ])
    }

    guard let mic = micBuf, let tap = tapBuf,
      let micData = mic.mData, let tapData = tap.mData
    else {
      return noErr  // one side missing this callback — skip (already logged)
    }

    let micCh = Int(mic.mNumberChannels)
    let tapCh = Int(tap.mNumberChannels)
    let micFrames = Int(mic.mDataByteSize) / (4 * micCh)
    let tapFrames = Int(tap.mDataByteSize) / (4 * tapCh)
    dbgCallbacks += 1
    dbgMicFrames += micFrames
    dbgTapFrames += tapFrames
    if micFrames != tapFrames { dbgMismatchCallbacks += 1 }
    let frames = min(micFrames, tapFrames)
    guard frames > 0 else { return noErr }

    ensureScratch(frames: frames)
    guard let out = interleaveScratch else { return noErr }

    let micF = micData.assumingMemoryBound(to: Float.self)
    let tapF = tapData.assumingMemoryBound(to: Float.self)
    for i in 0..<frames {
      // Mic → L (channel 0 if multichannel). Tap → mono → R.
      out[2 * i] = micF[i * micCh]
      var s: Float = 0
      for c in 0..<tapCh { s += tapF[i * tapCh + c] }
      out[2 * i + 1] = s / Float(tapCh)
    }

    outputHandler.handleAudioData(UnsafeRawPointer(out), count: frames * 8)
    return noErr
  }

  /// Diagnostic: log how many input streams the aggregate exposes and the
  /// channel count of each. Tells us whether the tap is surfacing at all.
  private func logInputStreamConfig() {
    var addr = getPropertyAddress(
      selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
      AudioTeeLogging.logger.error("Could not size input stream configuration")
      return
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else {
      AudioTeeLogging.logger.error("Could not read input stream configuration")
      return
    }
    let abl = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    var parts: [String] = []
    var total = 0
    for (i, b) in abl.enumerated() {
      parts.append("stream\(i)[ch=\(b.mNumberChannels)]")
      total += Int(b.mNumberChannels)
    }
    AudioTeeLogging.logger.info(
      "Aggregate input stream configuration",
      context: [
        "streams": String(abl.count), "total_channels": String(total),
        "detail": parts.joined(separator: " "),
      ])
  }

  private func ensureScratch(frames: Int) {
    if interleaveScratchFrames >= frames { return }
    interleaveScratch?.deallocate()
    interleaveScratch = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    interleaveScratchFrames = frames
  }

  public func stopRecording() {
    if dualMode {
      AudioTeeLogging.logger.info(
        "Dual frame-lock summary",
        context: [
          "callbacks": String(dbgCallbacks),
          "mic_frames": String(dbgMicFrames),
          "tap_frames": String(dbgTapFrames),
          "frame_delta": String(dbgMicFrames - dbgTapFrames),
          "mismatch_callbacks": String(dbgMismatchCallbacks),
        ])
    }
    if !dualMode {
      processAudioBuffer()
    }
    outputHandler.handleStreamStop()
    cleanupIOProc()
    interleaveScratch?.deallocate()
    interleaveScratch = nil
    interleaveScratchFrames = 0
  }

  private func processAudioBuffer() {
    audioBuffer?.processChunks { pointer, count in
      if let converter = self.converter {
        if !converter.transform(from: pointer, count: count, handler: { outPtr, outCount in
          self.outputHandler.handleAudioData(outPtr, count: outCount)
        }) {
          // Conversion failed — pass through unconverted audio
          self.outputHandler.handleAudioData(pointer, count: count)
        }
      } else {
        self.outputHandler.handleAudioData(pointer, count: count)
      }
    }
  }

  private func cleanupIOProc() {
    if let ioProcID = ioProcID {
      AudioDeviceStop(deviceID, ioProcID)
      AudioDeviceDestroyIOProcID(deviceID, ioProcID)
      self.ioProcID = nil
    }
  }
}
