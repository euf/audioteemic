import AudioToolbox
import CoreAudio
import Foundation

/// Resolves physical input devices (by name substring or the built-in mic)
/// to the CoreAudio device UID needed to add them as an aggregate sub-device.
public struct InputDevice {
  public let id: AudioObjectID
  public let uid: String
  public let name: String
  public let transportType: UInt32
  public let isBuiltIn: Bool
}

public enum AudioDeviceEnumerator {
  /// All devices that expose at least one input stream.
  public static func inputDevices() -> [InputDevice] {
    var addr = getPropertyAddress(selector: kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
    else { return [] }

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }

    var out: [InputDevice] = []
    for id in ids {
      guard hasInputStreams(id) else { continue }
      guard let uid = stringProp(id, kAudioDevicePropertyDeviceUID) else { continue }
      let name = stringProp(id, kAudioObjectPropertyName) ?? "(unknown)"
      let transport = uint32Prop(id, kAudioDevicePropertyTransportType) ?? 0
      out.append(
        InputDevice(
          id: id, uid: uid, name: name, transportType: transport,
          isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn))
    }
    return out
  }

  /// Pick an input device. If `nameSubstring` is given, first case-insensitive
  /// name match wins; otherwise the built-in mic; otherwise nil.
  public static func resolveInput(nameSubstring: String?) -> InputDevice? {
    let devices = inputDevices()
    if let needle = nameSubstring, !needle.isEmpty {
      let lc = needle.lowercased()
      if let hit = devices.first(where: { $0.name.lowercased().contains(lc) }) { return hit }
      AudioTeeLogging.logger.error(
        "No input device matched name", context: ["needle": needle])
      return nil
    }
    return devices.first(where: { $0.isBuiltIn })
      ?? devices.first(where: { $0.name.lowercased().contains("microphone") })
  }

  private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
    var addr = getPropertyAddress(
      selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
    return status == noErr && size > 0
  }

  private static func stringProp(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var addr = getPropertyAddress(selector: selector)
    var size = UInt32(MemoryLayout<CFString>.size)
    var value: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &value) { ptr in
      AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return status == noErr ? (value as String) : nil
  }

  private static func uint32Prop(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> UInt32?
  {
    var addr = getPropertyAddress(selector: selector)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
  }
}
