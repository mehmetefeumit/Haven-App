/// A [MaintenanceService] whose own-relay board a test sets, counting every
/// read, and whose session never opens.
library;

import 'package:haven/src/models/own_relay_board.dart';
import 'package:haven/src/services/maintenance_service.dart';

import '../mocks/mock_relay_service.dart';

/// Answers [board] to every [ownRelayBoard] read.
class FakeBoardSource extends MaintenanceService {
  /// Creates a source with no board.
  FakeBoardSource({this.board})
    : super(
        relayService: MockRelayService(),
        circleManagerFactory: () async => throw StateError('never opened'),
        identitySecretBytes: () async => const <int>[],
      );

  /// What the next read answers.
  OwnRelayBoard? board;

  /// How many times the board was read.
  int reads = 0;

  @override
  OwnRelayBoard? ownRelayBoard() {
    reads++;
    return board;
  }
}
