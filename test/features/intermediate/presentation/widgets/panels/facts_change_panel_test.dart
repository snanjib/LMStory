import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/facts_change_panel.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// FactsChangePanel 测试（事实层变更小窗，DOC-11 §4 配套）。
///
/// 验证：
/// 1. summarizing 阶段：显示「正在更新事实...」
/// 2. 完成态非空：折叠行「事实已更新 · N 项」
/// 3. 完成态空列表：显示「本轮无事实变更」占位
/// 4. 点击展开后显示变更记录的动作徽章
/// 5. 历史态：从 artifacts.factsChanges 渲染
void main() {
  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  List<FactsChangeRecord> changes() => const [
        FactsChangeRecord(
          action: FactAction.createEntity,
          entityType: 'character',
          primaryName: '李逍遥',
          newValue: '李逍遥',
          confidence: 5,
        ),
        FactsChangeRecord(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          oldValue: '开朗',
          newValue: '沉稳',
          reason: '剧情成长',
          confidence: 4,
        ),
      ];

  group('FactsChangePanel', () {
    testWidgets('1. summarizing 阶段：显示更新中提示', (tester) async {
      await tester.pumpWidget(
        wrap(
          const FactsChangePanel(
            phase: IntermediatePhase.summarizing,
            factsChanges: null,
            failureContext: null,
          ),
        ),
      );
      expect(find.textContaining('正在更新事实'), findsOneWidget);
    });

    testWidgets('2. 完成态非空：折叠行显示「事实已更新 · N 项」', (tester) async {
      await tester.pumpWidget(
        wrap(
          FactsChangePanel(
            phase: IntermediatePhase.idle,
            factsChanges: changes(),
            failureContext: null,
            foldDelayMs: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('事实已更新'), findsOneWidget);
      expect(find.textContaining('2 项'), findsOneWidget);
    });

    testWidgets('3. 完成态空列表：显示「本轮无事实变更」占位', (tester) async {
      await tester.pumpWidget(
        wrap(
          const FactsChangePanel(
            phase: IntermediatePhase.idle,
            factsChanges: [],
            failureContext: null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('本轮无事实变更'), findsOneWidget);
    });

    testWidgets('4. 点击展开后显示变更记录的动作徽章', (tester) async {
      await tester.pumpWidget(
        wrap(
          FactsChangePanel(
            phase: IntermediatePhase.idle,
            factsChanges: changes(),
            failureContext: null,
            foldDelayMs: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 点击折叠行展开
      await tester.tap(find.textContaining('事实已更新'));
      await tester.pumpAndSettle();
      // 展开后两条记录的动作徽章可见
      expect(find.text('新增'), findsOneWidget);
      expect(find.text('更新'), findsOneWidget);
    });

    testWidgets('5. 历史态：从 artifacts.factsChanges 渲染折叠行', (tester) async {
      final artifacts = StoryRoundArtifacts(
        sessionId: 'session-1',
        turnNumber: 3,
        createdAt: DateTime(2026),
        factsChanges: changes(),
      );
      await tester.pumpWidget(
        wrap(
          FactsChangePanel(
            phase: IntermediatePhase.idle,
            factsChanges: null,
            failureContext: null,
            artifacts: artifacts,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('事实已更新'), findsOneWidget);
    });

    testWidgets('6. 历史态空变更：显示「本轮无事实变更」', (tester) async {
      final artifacts = StoryRoundArtifacts(
        sessionId: 'session-1',
        turnNumber: 1,
        createdAt: DateTime(2026),
      );
      await tester.pumpWidget(
        wrap(
          FactsChangePanel(
            phase: IntermediatePhase.idle,
            factsChanges: null,
            failureContext: null,
            artifacts: artifacts,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('本轮无事实变更'), findsOneWidget);
    });
  });
}
