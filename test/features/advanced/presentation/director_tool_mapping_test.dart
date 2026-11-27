import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_round_runner.dart';
import 'package:lmstory/features/advanced/presentation/utils/agent_approval_labels.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/features/memory/domain/entities/facts_projection_note.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 工具名 → 消费方文案映射的完备性锁
///
/// stageVerbOf 与 approvalSummaryOf 都是字符串 switch，新工具漏 case 编译期
/// 无感——merge_entities 落"幕后工作"兜底/审批卡裸 dump 参数 Map 即该缺口
/// 的实证。本测试把"新增工具必须同步消费方映射"从 DoD 升级为
/// CI 红线：buildAgentTools 清单测试（agent_session_tools_test.dart）负责
/// 工具集本身，本文件负责 映射×工具集 的完整性。

ToolExecutionRequest _req(
  String name, [
  Map<String, dynamic> args = const {},
]) =>
    ToolExecutionRequest(
      callId: 'c-$name',
      toolName: name,
      arguments: args,
      permission: AgentToolPermission.write,
    );

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  /// 与 buildAgentTools 全变体（默认 9 + spawn + ask_user + read_skill）的
  /// 并集保持一致；新增工具时这里与映射函数同步加行。
  const knownTools = {
    'search_story',
    'search_story_text',
    'read_story',
    'query_facts',
    'list_facts',
    'query_memory_changes',
    'read_compact_summary',
    'update_facts',
    'merge_entities',
    'update_story_anchor',
    'record_event_memory',
    'finish_round',
    'finish_maintenance',
    'read_skill',
    'calc_eval',
    'calc_date',
    'spawn',
    'ask_user',
  };

  /// write 权限工具（监督模式必走审批摘要）
  const writeTools = {
    'update_facts',
    'merge_entities',
    'update_story_anchor',
    'record_event_memory',
  };

  test('每个已知工具在 stageVerbOf 有非 fallback 舞台动词', () {
    final t = LocaleSettings.instance.currentTranslations;
    const unknown = 'definitely_not_a_tool';
    final fallback = stageVerbOf(unknown, t);
    for (final name in knownTools) {
      final verb = stageVerbOf(name, t);
      expect(
        verb,
        isNot(equals(fallback)),
        reason: '$name 落入 fallback「幕后工作」——补 stageVerbOf case '
            '与 advanced.stage 词条',
      );
    }
  });

  test('每个 write 工具在 approvalSummaryOf 有专属人话摘要', () {
    final t = LocaleSettings.instance.currentTranslations;
    const unknown = 'definitely_not_a_tool';
    final generic = approvalSummaryOf(_req(unknown), t);
    for (final name in writeTools) {
      final summary = approvalSummaryOf(_req(name), t);
      expect(
        summary,
        isNot(equals(generic)),
        reason: '$name 落入 approvalGeneric 兜底——补 approvalSummaryOf '
            'case 与 advanced.hitl 词条',
      );
      expect(
        summary.contains('{') || summary.contains('toString'),
        isFalse,
        reason: '$name 摘要疑似裸 dump 参数',
      );
    }
  });

  test('merge_entities 审批摘要展示源/目标名而非原始 ID Map', () {
    final t = LocaleSettings.instance.currentTranslations;
    final summary = approvalSummaryOf(
      _req('merge_entities', const {
        'source_name': '庄园',
        'target_name': '边境庄园',
      }),
      t,
    );
    expect(summary, contains('庄园'));
    expect(summary, isNot(contains('{')));
  });

  test('importanceOutOfRange 审批提示映射到 i18n 文案', () {
    final t = LocaleSettings.instance.currentTranslations;
    const change = AgentApprovalChange(
      kind: ApprovalChangeKind.updateAttr,
      entityName: '林澈',
      details: ApprovalFactNotes([FactsProjectionNote.importanceOutOfRange]),
    );
    final row = formatApprovalChange(change, t);
    expect(row.note, t.advanced.approval.noteImportanceOutOfRange);
  });
}
