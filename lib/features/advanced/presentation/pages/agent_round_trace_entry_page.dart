import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_round_trace_page.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 轮轨迹入口页
///
/// 原设计入口为导演聊天轮卡片长按；该文件（director_chat_body.dart）存在
/// 并行会话未提交改动，按任务前置约定改从诊断页进入，长按入口记为遗留。
/// 列出最近的导演（advanced）会话，点选后输入轮号进入轨迹页。
/// 纯只读。页面级文案入 slang；技术标签（id/updated 数据行）为英文
/// 字面量，同 trace 页取舍。
class AgentRoundTraceEntryPage extends ConsumerStatefulWidget {
  const AgentRoundTraceEntryPage({super.key});

  @override
  ConsumerState<AgentRoundTraceEntryPage> createState() =>
      _AgentRoundTraceEntryPageState();
}

class _AgentRoundTraceEntryPageState
    extends ConsumerState<AgentRoundTraceEntryPage> {
  List<ChatSession>? _advancedSessions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final sessions = await ref.read(chatRepositoryProvider).getAllSessions();
      if (!mounted) return;
      setState(() {
        _advancedSessions = sessions.where((s) => s.mode == 'advanced').toList()
          ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
      });
    } catch (e, stackTrace) {
      // catch(_) 连 Error 一并吞掉——DB 损坏/迁移
      // 异常时留一条诊断线索（对齐 global_search_dialog 的  口径）
      debugPrint('Director trace entry load failed: $e\n$stackTrace');
      if (!mounted) return;
      setState(() => _advancedSessions = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final sessions = _advancedSessions;

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(context.lm.palette.bg),
      appBar: context.lmUi.appBar(
        context,
        title: t.settings.diagnostics.roundTrace.entryTitle,
      ),
      body: LmMeasure(
        child: sessions == null
            ? const Center(child: CircularProgressIndicator())
            : sessions.isEmpty
                ? Center(
                    child: Text(t.settings.diagnostics.roundTrace.noSessions),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(SimpleSpacing.sMd),
                    itemCount: sessions.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: SimpleSpacing.sSm),
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      return context.lmUi.card(
                        context,
                        onTap: () => _promptTurn(context, session),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    session.title.isEmpty
                                        ? _shortId(session.sessionId)
                                        : session.title,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: LmNarrativeTextStyles
                                        .narrativeDisplay
                                        .copyWith(color: colors.ink),
                                  ),
                                ),
                                const SizedBox(width: SimpleSpacing.sSm),
                                Icon(
                                  Icons.arrow_forward,
                                  color: colors.muted,
                                  size: 20,
                                ),
                              ],
                            ),
                            const SizedBox(height: SimpleSpacing.sSm),
                            Text(
                              'id: ${_shortId(session.sessionId, 12)}…'
                              '\nupdated: ${session.lastActiveAt.toIso8601String().substring(0, 16)}',
                              style: LmNarrativeTextStyles.caption
                                  .copyWith(color: colors.muted),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }

  Future<void> _promptTurn(BuildContext context, ChatSession session) async {
    final t = Translations.of(context);
    final controller = TextEditingController();
    final turn = await showLmDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.settings.diagnostics.roundTrace.turnNumber),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: t.settings.diagnostics.roundTrace.turnNumberHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(int.tryParse(controller.text.trim())),
            child: Text(t.settings.diagnostics.roundTrace.open),
          ),
        ],
      ),
    );
    // 对话框已关闭、值已取走——补 dispose
    controller.dispose();
    if (turn == null || turn < 1 || !context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AgentRoundTracePage(
          sessionId: session.sessionId,
          turnNumber: turn,
        ),
      ),
    );
  }
}

String _shortId(String id, [int max = 8]) =>
    id.length <= max ? id : id.substring(0, max);
