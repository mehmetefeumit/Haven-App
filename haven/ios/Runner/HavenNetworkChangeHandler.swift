import Flutter
import Network

/// Tells Dart (`PlatformNetworkChangeSource`) that the device's default network
/// changed, with an empty event: which network it was never crosses the
/// channel, and nothing here logs.
///
/// A change is a satisfied path whose key differs from the last one seen. The
/// first update after a listen is the baseline and emits nothing; a path that
/// is not satisfied clears the key, so whatever comes back emits once.
///
/// The key is the PREFERRED interface (the first of `availableInterfaces`,
/// the one the default route uses) and the path's gateways, sorted. Not the
/// whole interface list: its order flips between equally preferred interfaces
/// and secondary ones (`pdp_ip1`, a `utun`) come and go while the default
/// route stays put, and either would re-dial for nothing. The gateways are
/// what tell one Wi-Fi network from the next on the same `en0`; sorted, their
/// order cannot read as a change. What this key cannot see — a cellular
/// re-registration that keeps the interface and reports no gateway — is left
/// to the pool's ping, and how often a path update still changes it with no
/// new network is unmeasured; Dart's 30 s floor between iOS re-dials bounds
/// that (`kIosNetworkReconnectFloor`).
///
/// Listened to only while the app is in front (MapShell stops it at a pause).
/// A cancelled `NWPathMonitor` cannot be restarted, so each listen makes its
/// own, delivering on the main queue as the sink requires.
final class HavenNetworkChangeHandler: NSObject, FlutterStreamHandler {
  private static let channelName = "haven.app/network_change"

  private var monitor: NWPathMonitor?
  private var sink: FlutterEventSink?
  private var lastKey: String?
  private var baselined = false

  func register(with messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    ).setStreamHandler(self)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    monitor?.cancel()
    sink = events
    lastKey = nil
    baselined = false
    let listening = NWPathMonitor()
    listening.pathUpdateHandler = { [weak self, weak listening] path in
      // An update queued before a cancel can still arrive after it.
      guard let self = self, let listening = listening, self.monitor === listening else {
        return
      }
      self.update(HavenNetworkChangeHandler.key(of: path))
    }
    monitor = listening
    listening.start(queue: .main)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    monitor?.cancel()
    monitor = nil
    sink = nil
    return nil
  }

  private func update(_ key: String?) {
    if baselined, let key = key, key != lastKey {
      sink?(nil)
    }
    lastKey = key
    baselined = true
  }

  private static func key(of path: NWPath) -> String? {
    guard path.status == .satisfied,
          let preferred = path.availableInterfaces.first else { return nil }
    let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
    return "\(preferred.type)#\(preferred.name)#\(preferred.index)|\(gateways)"
  }
}
