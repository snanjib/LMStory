import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';

void main() {
  test('partial capture must block an enabled imported epoch', () {
    final events = [
      modeEpochEnterPendingEvent(epochId: 'e', fromTurn: 3),
      ...buildEngineeringCaptureEvents(
        visibleSurface: [AgentMessage.user('only remaining history row')],
        epochId: 'e',
      ),
      modeEpochEnterCompleteEvent(epochId: 'e', captureCount: 4),
    ];
    final result = resolveEngineeringMode(enabled: true, events: events);
    expect(
      result.mode,
      EngineeringRuntimeMode.recoveryRequired,
      reason:
          'The complete marker promises 4 captures but only 1 survives import',
    );
  });
}
