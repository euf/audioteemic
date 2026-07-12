import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public class AudioTapManager {
  private var tapID: AudioObjectID?
  private var deviceID: AudioObjectID?

  public init() {}

  deinit {
    AudioTeeLogging.logger.debug("Cleaning up audio tap manager")

    if let tapID = tapID {
      AudioHardwareDestroyProcessTap(tapID)
      self.tapID = nil
    }

    if let deviceID = deviceID {
      AudioHardwareDestroyAggregateDevice(deviceID)
      self.deviceID = nil
    }
  }

  /// Sets up the audio tap and aggregate device.
  ///
  /// When `inputDeviceUID` is non-nil, that input device (e.g. the built-in
  /// mic) is added as a sub-device of the same private aggregate and made the
  /// clock master; the system tap is drift-compensated to it. The result is a
  /// single IOProc that delivers mic + system audio time-aligned on one clock
  /// (no cross-recorder drift). The mic — not the tap — is master on purpose:
  /// its hardware clock is stable, whereas the tap follows the output device,
  /// which changes when AirPods connect/disconnect mid-call.
  public func setupAudioTap(with config: TapConfiguration, inputDeviceUID: String? = nil) throws {
    AudioTeeLogging.logger.debug(
      "Setting up audio tap manager",
      context: ["input_device_uid": inputDeviceUID ?? "(none)"])

    tapID = try createSystemAudioTap(with: config)
    deviceID = try createAggregateDevice(inputDeviceUID: inputDeviceUID)

    guard let tapID = tapID, let deviceID = deviceID else {
      throw AudioTeeError.setupFailed
    }

    // Drift-compensate the tap only when it is NOT the sole clock source, i.e.
    // when a master sub-device (the mic) is present.
    try addTapToAggregateDevice(
      tapID: tapID, deviceID: deviceID, driftCompensate: inputDeviceUID != nil)

    AudioTeeLogging.logger.debug("Audio tap manager setup complete")
  }

  /// Returns the aggregate device ID for recording
  public func getDeviceID() -> AudioObjectID? {
    return deviceID
  }

  private func createSystemAudioTap(with config: TapConfiguration) throws -> AudioObjectID {
    AudioTeeLogging.logger.debug("Creating tap description")
    let description = CATapDescription()

    description.name = "audiotee-tap"
    description.processes = try translatePIDsToProcessObjects(config.processes)  // Properly translate PIDs
    description.isPrivate = true
    description.muteBehavior = config.muteBehavior.coreAudioValue
    description.isMixdown = true
    description.isMono = config.isMono
    description.isExclusive = config.isExclusive
    description.deviceUID = nil  // system default
    description.stream = 0  // first stream of output device

    AudioTeeLogging.logger.debug(
      "Tap description configured",
      context: [
        "name": description.name,
        "processes": String(describing: config.processes),
        "mute": String(describing: description.muteBehavior),
        "mono": String(description.isMono),
        "exclusive": String(description.isExclusive),
      ])

    // Create the tap
    AudioTeeLogging.logger.debug("Creating tap")
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateProcessTap(description, &tapID)

    AudioTeeLogging.logger.debug(
      "AudioHardwareCreateProcessTap completed", context: ["status": String(status)])
    guard status == kAudioHardwareNoError else {
      AudioTeeLogging.logger.error(
        "Failed to create audio tap", context: ["status": String(status)])
      throw AudioTeeError.tapCreationFailed(status)
    }

    // Get the format of the audio tap
    var propertyAddress = getPropertyAddress(selector: kAudioTapPropertyFormat)
    var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
    var streamDescription = AudioStreamBasicDescription()
    let formatStatus = AudioObjectGetPropertyData(
      tapID, &propertyAddress, 0, nil, &propertySize, &streamDescription)

    if formatStatus == noErr {
      AudioTeeLogging.logger.debug(
        "Tap format retrieved",
        context: [
          "channels": String(streamDescription.mChannelsPerFrame),
          "sample_rate": String(Int(streamDescription.mSampleRate)),
        ])
    }

    return tapID
  }

  private func createAggregateDevice(inputDeviceUID: String?) throws -> AudioObjectID {
    let uid = UUID().uuidString

    // With a mic sub-device present, list it and make it clock master. Its own
    // drift compensation stays off (it defines the clock); the tap is
    // compensated in addTapToAggregateDevice.
    var subDeviceList: [[String: Any]] = []
    var masterKey: Any = 0
    if let inputUID = inputDeviceUID {
      subDeviceList = [
        [
          kAudioSubDeviceUIDKey as String: inputUID,
          kAudioSubDeviceDriftCompensationKey as String: 0,
        ]
      ]
      masterKey = inputUID
    }

    let description =
      [
        kAudioAggregateDeviceNameKey: "audioteemic-aggregate-device",
        kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
        kAudioAggregateDeviceMasterSubDeviceKey: masterKey,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
      ] as [String: Any]

    var deviceID: AudioObjectID = 0
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)

    guard status == kAudioHardwareNoError else {
      AudioTeeLogging.logger.error(
        "Failed to create aggregate device", context: ["status": String(status)])
      throw AudioTeeError.aggregateDeviceCreationFailed(status)
    }

    return deviceID
  }

  private func addTapToAggregateDevice(
    tapID: AudioObjectID, deviceID: AudioObjectID, driftCompensate: Bool
  ) throws {
    // Get the tap's UID
    var propertyAddress = getPropertyAddress(selector: kAudioTapPropertyUID)
    var propertySize = UInt32(MemoryLayout<CFString>.stride)
    var tapUID: CFString = "" as CFString
    _ = withUnsafeMutablePointer(to: &tapUID) { tapUID in
      AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &propertySize, tapUID)
    }

    // Add the tap to the aggregate device using the plain-UID array form.
    //
    // We do NOT use the dictionary form with kAudioSubTapDriftCompensationKey:
    // on macOS 26 it silently prevents the tap from surfacing as an input
    // stream at all (verified — tried both Int and kCFBooleanTrue values). It
    // isn't needed anyway: the mic and tap are composited into ONE aggregate
    // whose master clock is the mic, and the IOProc delivers both streams in a
    // single callback with equal frame counts. Every output frame therefore
    // pairs mic[i] with tap[i] from the same clock cycle, so the cumulative
    // L↔R drift of the old two-process design cannot occur. `driftCompensate`
    // is retained only to gate the post-condition check below.
    _ = driftCompensate
    propertyAddress = getPropertyAddress(selector: kAudioAggregateDevicePropertyTapList)
    let tapArray = [tapUID] as CFArray
    propertySize = UInt32(MemoryLayout<CFArray>.stride)
    let status = withUnsafePointer(to: tapArray) { ptr in
      AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, propertySize, ptr)
    }

    guard status == kAudioHardwareNoError else {
      AudioTeeLogging.logger.error(
        "Failed to add tap to aggregate device", context: ["status": String(status)])
      throw AudioTeeError.tapAssignmentFailed(status)
    }

    // Hard post-condition: the tap must actually surface, otherwise we would
    // silently record mic-only (system audio missing) — the worst failure for
    // a meeting recorder. But surfacing is ASYNCHRONOUS: SetPropertyData above
    // returns success before the aggregate finishes recomposing its input
    // stream configuration, so a single immediate read races and can miss the
    // tap. Poll for up to ~1s (this is exactly why AudioFormatManager polls
    // device readiness too). Fail loudly only if it never appears.
    var surfaced = false
    for _ in 0..<40 {
      if tapIsSurfacing(deviceID) {
        surfaced = true
        break
      }
      Thread.sleep(forTimeInterval: 0.025)
    }
    guard surfaced else {
      AudioTeeLogging.logger.error(
        "Tap did not surface as an aggregate input stream within timeout")
      throw AudioTeeError.tapAssignmentFailed(kAudioHardwareUnspecifiedError)
    }
  }

  /// True if the aggregate exposes more than the mic's single input channel,
  /// i.e. the tap's stream is present.
  private func tapIsSurfacing(_ deviceID: AudioObjectID) -> Bool {
    var addr = getPropertyAddress(
      selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
      return false
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else {
      return false
    }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    let total = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    return total >= 2
  }
}
