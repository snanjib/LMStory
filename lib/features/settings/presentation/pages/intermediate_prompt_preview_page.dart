import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/intermediate/domain/services/intermediate_context_builder.dart';
import 'package:lmstory/features/settings/presentation/support/intermediate_preview_mock_data.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式提示词拼接预览页（预览功能）。
///
/// 全屏只读展示当前提示词配置下，四步生成中四个 LLM 请求实际发送的
/// messages 列表，帮助用户调参时直观看到每段提示词如何被组装。
///
/// 四步流程：
/// - generating（生成）：system_prompt + 对话历史 + 用户消息 → 生成内容
/// - extracting（提取）：extractKeywordsPrompt + 用户消息 → 关键词
/// - reviewing（审查）：system_prompt + 历史 + 生成内容 + 记忆 + 用户消息 → 回复
/// - summarizing（摘要）：extractSummaryPrompt + 回复 → 事件摘要
///
/// 数据来源：
/// - 提示词配置：[intermediateConfigProvider]（当前生效的 IntermediateConfig）
/// - 模拟输入：[IntermediatePreviewMockData]
/// - 拼装逻辑：[IntermediateContextBuilder]（与控制器实际调用同源，V2 方法）
///
/// 交互：
/// - TabBar 切换四步流程（生成/提取/审查/摘要），支持左右滑动
/// - extract/summarize Tab 展示工具调用模式信息（从 config 读取，不可切换）
/// - 技术用户可展开查看工具定义 JSON Schema
/// - 每条消息以 role 胶囊徽章 + 等宽内容展示，可选中复制
///
/// 视觉：夜航主题，与 IntermediateSettingsPage / IntermediatePromptEditorPage 一致。
class IntermediatePromptPreviewPage extends ConsumerStatefulWidget {
  const IntermediatePromptPreviewPage({super.key});

  @override
  ConsumerState<IntermediatePromptPreviewPage> createState() =>
      _IntermediatePromptPreviewPageState();
}

class _IntermediatePromptPreviewPageState
    extends ConsumerState<IntermediatePromptPreviewPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _toolCallingEnabled = true;
  _PreviewResult? _generateResult;
  _PreviewResult? _extractResult;
  _PreviewResult? _reviewResult;
  _PreviewResult? _summarizeResult;
  // token 预算信息（仅 generating/reviewing，技术用户参考）
  _TokenBudgetInfo? _generateBudget;
  _TokenBudgetInfo? _reviewBudget;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final config = ref.read(intermediateConfigProvider).valueOrNull;
    if (config != null && _generateResult == null) {
      _toolCallingEnabled = config.stream.toolCallingEnabled;
      _assemble();
    }
  }

  Future<void> _assemble() async {
    final config = ref.read(intermediateConfigProvider).valueOrNull;
    if (config == null) return;
    final tokenCounter = ref.read(tokenCounterProvider);
    final builder = IntermediateContextBuilder(tokenCounter: tokenCounter);

    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final generateMessages = await builder.buildGenerateMessagesV2(
        userInput: IntermediatePreviewMockData.userInput,
        history: IntermediatePreviewMockData.history,
        sessionSystemPrompt: null,
        //  修复：补传压缩摘要——压缩过的会话实际请求中
        // 存在第 2 条 system 摘要消息，预览此前永远缺席该条
        compactionSummary: IntermediatePreviewMockData.compactionSummary,
        // v0.2.2 阶段 2-F：maxContextMessages 已移除
        contextWindow: IntermediatePreviewMockData.contextWindow,
        // v0.2.2：outputReserve 废弃，统一用 maxTokens
        maxTokens: config.generation.maxTokens,
        prompts: config.prompts,
        globalSystemPrompt: config.systemPrompt,
        // generating 也注入记忆，预览展示真实生产行为。
        // factBlock 传空字符串（与 reviewing 预览一致，事实层未启用场景）。
        retrievedMemories: IntermediatePreviewMockData.retrievedMemories,
        factBlock: '',
        currentTurnNumber: IntermediatePreviewMockData.currentTurnNumber,
      );
      final extractMessages = builder.buildExtractMessagesV2(
        userInput: IntermediatePreviewMockData.userInput,
        history: IntermediatePreviewMockData.history,
        //  修复：extract 请求同样注入压缩摘要（与生产一致）
        compactionSummary: IntermediatePreviewMockData.compactionSummary,
        prompts: config.prompts,
      );
      final reviewMessages = await builder.buildReviewMessagesV2(
        userInput: IntermediatePreviewMockData.userInput,
        generated: IntermediatePreviewMockData.generated,
        retrievedMemories: IntermediatePreviewMockData.retrievedMemories,
        sessionSystemPrompt: null,
        contextWindow: IntermediatePreviewMockData.contextWindow,
        maxTokens: config.generation.maxTokens,
        currentTurnNumber: IntermediatePreviewMockData.currentTurnNumber,
        prompts: config.prompts,
        globalSystemPrompt: config.systemPrompt,
      );
      final summarizeMessages = builder.buildSummarizeMessagesV2(
        userInput: IntermediatePreviewMockData.userInput,
        reply: IntermediatePreviewMockData.reply,
        prompts: config.prompts,
      );

      final results = await Future.wait([
        _countTotalTokens(tokenCounter, generateMessages),
        _countTotalTokens(tokenCounter, extractMessages),
        _countTotalTokens(tokenCounter, reviewMessages),
        _countTotalTokens(tokenCounter, summarizeMessages),
      ]);

      if (!mounted) return;
      // 创建 token 预算信息（generating 无比例，reviewing 有比例）
      final generateBudget = _TokenBudgetInfo(
        contextWindow: IntermediatePreviewMockData.contextWindow,
        maxTokens: config.generation.maxTokens,
      );
      final reviewBudget = _TokenBudgetInfo(
        contextWindow: IntermediatePreviewMockData.contextWindow,
        maxTokens: config.generation.maxTokens,
      );
      setState(() {
        _generateResult =
            _PreviewResult(messages: generateMessages, tokenCount: results[0]);
        _extractResult =
            _PreviewResult(messages: extractMessages, tokenCount: results[1]);
        _reviewResult =
            _PreviewResult(messages: reviewMessages, tokenCount: results[2]);
        _summarizeResult =
            _PreviewResult(messages: summarizeMessages, tokenCount: results[3]);
        _generateBudget = generateBudget;
        _reviewBudget = reviewBudget;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<int> _countTotalTokens(
    TokenCounter counter,
    List<Map<String, String>> messages,
  ) async {
    final text = messages.map((m) => m['content'] ?? '').join('\n');
    return counter.countTokens(text);
  }

  @override
  Widget build(BuildContext context) {
    return _buildScaffold();
  }

  Widget _buildScaffold() {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.intermediate.preview.title,
            style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          ),
        ),
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: Column(
        children: [
          _buildMockBanner(colors, t),
          if (_error != null)
            _buildError(colors, _error!)
          else if (_loading ||
              _generateResult == null ||
              _extractResult == null ||
              _reviewResult == null ||
              _summarizeResult == null)
            Expanded(child: _buildLoading(colors))
          else
            Expanded(
              child: Column(
                children: [
                  _buildTabBar(colors, t),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _PreviewTabContent(
                          result: _generateResult!,
                          stepDesc:
                              t.settings.intermediate.preview.generateStep,
                          tokenBudget: _generateBudget,
                        ),
                        _PreviewTabContent(
                          result: _extractResult!,
                          stepDesc: t.settings.intermediate.preview.extractStep,
                          toolCallingEnabled: _toolCallingEnabled,
                          toolDefinition: kExtractKeywordsToolDefinition,
                        ),
                        _PreviewTabContent(
                          result: _reviewResult!,
                          stepDesc: t.settings.intermediate.preview.reviewStep,
                          tokenBudget: _reviewBudget,
                        ),
                        _PreviewTabContent(
                          result: _summarizeResult!,
                          stepDesc:
                              t.settings.intermediate.preview.summarizeStep,
                          toolCallingEnabled: _toolCallingEnabled,
                          toolDefinition: kExtractSummaryToolDefinition,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMockBanner(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sLg,
        vertical: IntermediateSpacing.s2xs,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sMd,
          vertical: IntermediateSpacing.sSm,
        ),
        decoration: BoxDecoration(
          color: colors.accentDim,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: colors.accent),
            const SizedBox(width: IntermediateSpacing.sSm),
            Expanded(
              child: Text(
                t.settings.intermediate.preview.mockBanner,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(LmPalette colors, Translations t) {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sLg,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.divider)),
      ),
      child: TabBar(
        controller: _tabController,
        labelColor: colors.primary,
        unselectedLabelColor: colors.muted,
        indicatorColor: colors.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: IntermediateTextStyles.label,
        unselectedLabelStyle: IntermediateTextStyles.label,
        tabs: [
          Tab(text: t.settings.intermediate.preview.generateTab),
          Tab(text: t.settings.intermediate.preview.extractTab),
          Tab(text: t.settings.intermediate.preview.reviewTab),
          Tab(text: t.settings.intermediate.preview.summarizeTab),
        ],
      ),
    );
  }

  Widget _buildLoading(LmPalette colors) {
    return Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.muted,
        ),
      ),
    );
  }

  Widget _buildError(LmPalette colors, String error) {
    return Padding(
      padding: const EdgeInsets.all(IntermediateSpacing.sXl),
      child: Center(
        child: Text(
          error,
          textAlign: TextAlign.center,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.error),
        ),
      ),
    );
  }
}

/// 单个 Tab 的完整内容：步骤说明 + 工具调用信息（可选）+ 统计头 + 消息卡片。
class _PreviewTabContent extends StatelessWidget {
  const _PreviewTabContent({
    required this.result,
    required this.stepDesc,
    this.toolCallingEnabled,
    this.toolDefinition,
    this.tokenBudget,
  });

  final _PreviewResult result;
  final String stepDesc;

  /// 非 null 时表示此步骤支持工具调用（extracting/summarizing），
  /// 展示工具调用模式信息条。
  final bool? toolCallingEnabled;
  final ToolDefinition? toolDefinition;

  /// 非 null 时表示此步骤有 token 预算控制（generating/reviewing），
  /// 展示上下文窗口、输出预留、对话预算比例。
  final _TokenBudgetInfo? tokenBudget;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        IntermediateSpacing.sLg,
        IntermediateSpacing.sMd,
        IntermediateSpacing.sLg,
        IntermediateSpacing.s2xl,
      ),
      children: [
        _buildStepDesc(context, colors, t),
        if (toolCallingEnabled != null) _buildToolCallingInfo(colors, t),
        // 统计头：消息数 + token 估算
        Padding(
          padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
          child: Text(
            t.settings.intermediate.preview.stats(
              n: result.messages.length,
              count: result.messages.length,
              tokens: result.tokenCount,
            ),
            style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
          ),
        ),
        // token 预算信息（仅 generating/reviewing，技术用户参考）
        if (tokenBudget != null)
          Padding(
            padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
            child: Text(
              t.settings.intermediate.preview.budgetInfo(
                context: tokenBudget!.contextWindow,
                reserve: tokenBudget!.maxTokens,
              ),
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        for (var i = 0; i < result.messages.length; i++) ...[
          if (i > 0) const SizedBox(height: IntermediateSpacing.sSm),
          _MessageCard(
            index: i + 1,
            role: result.messages[i]['role'] ?? '',
            content: result.messages[i]['content'] ?? '',
          ),
        ],
      ],
    );
  }

  /// 步骤说明（小白用户）：用 accent 色左竖线 + 简短说明
  Widget _buildStepDesc(
    BuildContext context,
    LmPalette colors,
    Translations t,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 16,
            margin: const EdgeInsets.only(top: 3),
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(
                context.lmUi.radius(LmCorner.full),
              ),
            ),
          ),
          const SizedBox(width: IntermediateSpacing.sSm),
          Expanded(
            child: Text(
              stepDesc,
              style: IntermediateTextStyles.bodyUi
                  .copyWith(color: colors.ink, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 工具调用信息条（技术用户）：展示当前模式 + 可展开工具定义
  Widget _buildToolCallingInfo(LmPalette colors, Translations t) {
    return _ToolCallingInfoBar(
      enabled: toolCallingEnabled!,
      toolDefinition: toolDefinition!,
    );
  }
}

/// 工具调用模式信息条（extracting/summarizing 步骤专用）。
///
/// 从 config 读取 toolCallingEnabled，展示当前模式说明。
/// 技术用户可展开查看工具定义 JSON Schema。
class _ToolCallingInfoBar extends StatefulWidget {
  const _ToolCallingInfoBar({
    required this.enabled,
    required this.toolDefinition,
  });

  final bool enabled;
  final ToolDefinition toolDefinition;

  @override
  State<_ToolCallingInfoBar> createState() => _ToolCallingInfoBarState();
}

class _ToolCallingInfoBarState extends State<_ToolCallingInfoBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final label = widget.enabled
        ? t.settings.intermediate.preview.toolCallingOn
        : t.settings.intermediate.preview.toolCallingOff;
    final desc = widget.enabled
        ? t.settings.intermediate.preview.toolCallingOnDesc
        : t.settings.intermediate.preview.toolCallingOffDesc;

    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        child: Column(
          children: [
            // 模式标签行
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sMd,
                vertical: IntermediateSpacing.sSm,
              ),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: widget.enabled ? colors.primary : colors.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: IntermediateSpacing.sSm),
                  Expanded(
                    child: Text(
                      label,
                      style: IntermediateTextStyles.label.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.enabled)
                    GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _expanded
                                ? t.settings.intermediate.preview
                                    .hideToolDefinition
                                : t.settings.intermediate.preview
                                    .showToolDefinition,
                            style: IntermediateTextStyles.caption.copyWith(
                              color: colors.primary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Icon(
                            _expanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 16,
                            color: colors.primary,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            // 模式描述
            Padding(
              padding: const EdgeInsets.only(
                left: IntermediateSpacing.sMd,
                right: IntermediateSpacing.sMd,
                bottom: IntermediateSpacing.sSm,
              ),
              child: Text(
                desc,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted, height: 1.5),
              ),
            ),
            // 工具定义（展开时）
            if (_expanded && widget.enabled) ...[
              Divider(height: 1, color: colors.divider),
              Padding(
                padding: const EdgeInsets.all(IntermediateSpacing.sMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.settings.intermediate.preview.toolDefinition,
                      style: IntermediateTextStyles.caption.copyWith(
                        color: colors.faint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: IntermediateSpacing.sXs),
                    SelectableText(
                      _formatToolDefinition(widget.toolDefinition),
                      style: IntermediateTextStyles.bodyUi.copyWith(
                        fontFamily: 'monospace',
                        height: 1.6,
                        color: colors.ink,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatToolDefinition(ToolDefinition def) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(def.toRequestBody());
  }
}

/// 单条消息卡片：序号 + role 胶囊徽章 + 等宽内容。
///
/// role 区分用胶囊徽章（非侧条纹，impeccable 禁令）：
/// - system：accent 底 + accent 文字
/// - user：primary 底 + primary 文字
/// - assistant：muted 底 + ink 文字
class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.index,
    required this.role,
    required this.content,
  });

  final int index;
  final String role;
  final String content;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final (roleLabel, roleColor) = _roleStyle(role, t, colors);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#$index',
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.faint,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: IntermediateSpacing.sSm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.16),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
                ),
                child: Text(
                  roleLabel,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: roleColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: IntermediateSpacing.sSm),
          // 等宽展示提示词内容，便于逐字审视与复制。
          // 不加 fontFamilyFallback（同日志查看器修复）：让 Flutter 系统
          // 字体兜底中文，避免 RobotoMono 等拦截中文字形显示为方块。
          SelectableText(
            content,
            style: IntermediateTextStyles.bodyUi.copyWith(
              fontFamily: 'monospace',
              height: 1.6,
              color: colors.ink,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _roleStyle(
    String role,
    Translations t,
    LmPalette colors,
  ) {
    switch (role) {
      case 'system':
        return (t.settings.intermediate.preview.roleSystem, colors.accent);
      case 'user':
        return (t.settings.intermediate.preview.roleUser, colors.primary);
      case 'assistant':
        return (t.settings.intermediate.preview.roleAssistant, colors.muted);
      default:
        return (role, colors.muted);
    }
  }
}

/// 预览拼装结果（messages + token 估算）。
class _PreviewResult {
  const _PreviewResult({required this.messages, required this.tokenCount});

  final List<Map<String, String>> messages;
  final int tokenCount;
}

/// Token 预算信息（仅 generating/reviewing 步骤，技术用户参考）。
///
/// 展示上下文窗口与输出预留（maxTokens），让技术用户了解 token 预算分配。
/// v0.2.2：去掉 dialogueBudgetRatio，generating/reviewing 统一不塞满不截断。
class _TokenBudgetInfo {
  const _TokenBudgetInfo({
    required this.contextWindow,
    required this.maxTokens,
  });

  final int contextWindow;
  final int maxTokens;
}
