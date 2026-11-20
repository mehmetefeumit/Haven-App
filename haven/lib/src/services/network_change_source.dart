import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tells the app that the device's default network changed.
///
/// An interface rather than a bare function: it is the seam the reconnector's
/// tests swap for a fake platform.
// ignore: one_member_abstracts
abstract class NetworkChangeSource {
  /// One event for each change of the default network the platform reports
  /// while this is listened to, carrying nothing. The platform takes the
  /// network in use at the listen as its baseline, so a listen reports no
  /// change of its own, and a loss of every network reports none.
  Stream<void> changes();
}

/// [NetworkChangeSource] over the native `haven.app/network_change` channel:
/// Android's `NetworkChangeStream.kt` and iOS's
/// `HavenNetworkChangeHandler.swift`. The native side compares networks
/// itself and sends no detail of them, so nothing about the network crosses
/// the channel.
class PlatformNetworkChangeSource implements NetworkChangeSource {
  /// Creates the platform source.
  const PlatformNetworkChangeSource();

  /// The event channel the native handlers serve.
  @visibleForTesting
  static const EventChannel channel = EventChannel('haven.app/network_change');

  @override
  Stream<void> changes() => channel.receiveBroadcastStream().map((_) {});
}
