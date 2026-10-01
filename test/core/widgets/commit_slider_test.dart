import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';

void main() {
  testWidgets('drag from thumb previews locally and commits on release',
      (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommitSlider(
              value: 1000,
              min: 100,
              max: 2000,
              divisions: 19,
              onCommit: committed.add,
            ),
          ),
        ),
      ),
    );

    // value 1000 in [100,2000] → thumb near horizontal center.
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(CommitSlider)));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();

    expect(committed, isEmpty);

    await gesture.up();
    await tester.pump();

    expect(committed, hasLength(1));
    expect(committed.single, greaterThan(1000));
  });

  testWidgets('tap on the track does not move the value', (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommitSlider(
              value: 100, // thumb at far left
              min: 100,
              max: 2000,
              divisions: 19,
              onCommit: committed.add,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(CommitSlider));
    await tester.pump();

    expect(committed, isEmpty);
  });

  testWidgets('drag starting off the thumb does not change the value',
      (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommitSlider(
              value: 100, // thumb at far left
              min: 100,
              max: 2000,
              divisions: 19,
              onCommit: committed.add,
            ),
          ),
        ),
      ),
    );

    // Start at the box center (far from the leftmost thumb) and drag.
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(CommitSlider)));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(committed, isEmpty);
  });

  testWidgets('disabled slider does not commit', (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommitSlider(
              value: 1000,
              min: 100,
              max: 2000,
              divisions: 19,
              enabled: false,
              onCommit: committed.add,
            ),
          ),
        ),
      ),
    );

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(CommitSlider)));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(committed, isEmpty);
  });

  testWidgets('tap focuses the slider without changing the value',
      (tester) async {
    double? committed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommitSlider(
              value: 100,
              min: 100,
              max: 2000,
              divisions: 19,
              onCommit: (v) => committed = v,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(CommitSlider));
    await tester.pump();

    // 纯点击只获焦不跳值（DOC-14 §3.1）
    expect(committed, isNull);

    // 获焦后方向键才可用（下一步断言的先决条件）
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(committed, 200); // step = (2000 - 100) / 19 = 100
  });

  testWidgets('arrow keys step and commit when focused', (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommitSlider(
              value: 1000,
              min: 100,
              max: 2000,
              divisions: 19,
              onCommit: committed.add,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(CommitSlider));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(committed, [1100, 1000]);
  });

  testWidgets('Home/End jump to min/max when focused', (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommitSlider(
              value: 1000,
              min: 100,
              max: 2000,
              divisions: 19,
              onCommit: committed.add,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(CommitSlider));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();

    expect(committed, [2000, 100]);
  });
}
