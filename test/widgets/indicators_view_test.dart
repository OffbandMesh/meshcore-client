// Widget tests for the Display and LED pane (#523/#1098).
//
// These pin the crash the adversarial review caught before this was pushed:
// the rotation control force-unwrapped `displayRotation`, but the capability
// tag that ENABLES the control arrives in the `0xC5` `0x1C` advert, which lands
// BEFORE the rotation GET reply that supplies the value. So on any slow link
// the pane was built with the control enabled and the value still null, and it
// threw. The display-mode control beside it was already null-safe; only
// rotation was not.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/screens/settings/indicators_view.dart';

/// Rotation is advertised, but the radio has not answered the GET yet. This is
/// the real window between the advert reply and the rotation reply.
class _RotationUnanswered extends MeshCoreConnector {
  @override
  bool get supportsIndicators => true;
  @override
  bool get supportsDisplayRotation => true;
  @override
  int? get displayRotation => null;
}

class _RotationAnswered extends MeshCoreConnector {
  _RotationAnswered(this._degrees);
  final int _degrees;
  @override
  bool get supportsIndicators => true;
  @override
  bool get supportsDisplayRotation => true;
  @override
  int? get displayRotation => _degrees;
}

Future<void> _pump(WidgetTester tester, MeshCoreConnector connector) =>
    tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: const MaterialApp(home: Scaffold(body: IndicatorsView())),
      ),
    );

void main() {
  testWidgets(
    'the pane builds before the radio has answered the rotation GET',
    (tester) async {
      await _pump(tester, _RotationUnanswered());

      // If this ever fails again, something is force-unwrapping a value that is
      // null for the whole window between the advert and the GET reply.
      expect(tester.takeException(), isNull);
      expect(find.text('Rotation'), findsOneWidget);
    },
  );

  testWidgets('no rotation is shown as chosen until the radio answers', (
    tester,
  ) async {
    await _pump(tester, _RotationUnanswered());

    final button = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    // An empty selection, not a guessed default: showing "Normal" here would
    // claim a rotation the radio never reported.
    expect(button.selected, isEmpty);
    expect(button.emptySelectionAllowed, isTrue);
  });

  testWidgets('the rotation the radio reported is the one shown', (
    tester,
  ) async {
    await _pump(tester, _RotationAnswered(180));

    final button = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(button.selected, {180});
  });

  testWidgets('a radio that does not advertise rotation gets no control', (
    tester,
  ) async {
    await _pump(tester, _DummyConnector());

    expect(find.text('Rotation'), findsNothing);
    expect(find.byType(SegmentedButton<int>), findsNothing);
  });
}

class _DummyConnector extends MeshCoreConnector {}
