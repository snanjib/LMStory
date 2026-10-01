/// AI 建卡对话页（resource_ai）。
///
/// 新建：只传 kind；编辑：另带目标 id 与原文留底（覆盖保存 patch 用）。
/// 相位渲染：idle=内联模型选择门；ready/generating/saving=消息流+输入栏；
/// fatal=错误横幅可重试。退出拦截：有过对话未保存时确认。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_app_bar.dart';
import 'package:lmstory/core/theme/simple/components/simple_markdown_body.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/file_reader.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_reader_web.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/presentation/controllers/resource_ai_controller.dart';
import 'package:lmstory/features/resource_ai/presentation/resource_ai_providers.dart';
import 'package:lmstory/features/resource_ai/presentation/widgets/draft_change_labels.dart';
import 'package:lmstory/features/resource_ai/presentation/widgets/resource_ai_session_settings_sheet.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_import_service.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

class ResourceAiPage extends ConsumerStatefulWidget {
  const ResourceAiPage({
    required this.kind,
    super.key,
    this.targetCardId,
    this.targetBookId,
    this.targetSummary,
    this.originalRawJson,
  });

  final DraftKind kind;
  final String? targetCardId;
  final String? targetBookId;
  final String? targetSummary;

  /// 编辑留底（覆盖保存 patch 语义：未知字段保留）。
  final String? originalRawJson;

  @override
  ConsumerState<ResourceAiPage> createState() => _ResourceAiPageState();
}

class _ResourceAiPageState extends ConsumerState<ResourceAiPage> {
  ResourceAiController? _controller;

  /// WA13U-3：boot 失败错误态（构建器抛错不再永久转圈）
  String? _bootError;
  final _inputController = TextEditingController();
  bool _bannerDismissed = false;

  /// saved 终态只消费一次（弹 toast + 自动退出）。
  bool _savedHandled = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final controller = await ref.read(resourceAiControllerBuilderProvider)(
        kind: widget.kind,
        targetCardId: widget.targetCardId,
        targetBookId: widget.targetBookId,
        targetSummary: widget.targetSummary,
        originalRawJson: widget.originalRawJson,
      );
      if (!mounted) return;
      controller.addListener(_onStateChanged);
      await controller.start();
      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (e) {
      // WA13U-3：预填构建抛错（如畸形 worldbook key 标量）
      // 此前无 try/catch → _controller 恒 null → 页面永久转圈。
      if (!mounted) return;
      setState(() => _bootError = e.toString());
    }
  }

  void _onStateChanged() {
    _bannerDismissed = false;
    final controller = _controller;
    if (controller != null &&
        controller.state.phase == ResourceAiPhase.saved &&
        !_savedHandled) {
      _savedHandled = true;
      if (mounted) {
        final t = Translations.of(context);
        // 根 messenger 弹 toast：随后连关设置面板与本页，toast 仍存活。
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(t.resourceAi.savedToast),
            ),
          );
        final navigator = Navigator.of(context);
        // 先清掉本页之上的路由（设置面板等），再退出本页。
        final route = ModalRoute.of(context);
        navigator.popUntil((r) => r == route);
        if (navigator.canPop()) {
          navigator.pop();
        }
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onStateChanged);
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final controller = _controller;
    final state = controller?.state;
    final error = state?.error;
    final errorText = error == null ? '' : _errorText(t, error);
    final busy = state?.phase == ResourceAiPhase.generating ||
        state?.phase == ResourceAiPhase.saving;

    return PopScope(
      canPop: state?.phase == ResourceAiPhase.saved ||
          !(state?.draft?.hasConversation ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExit();
      },
      child: Scaffold(
        backgroundColor: context.scaffoldBgOf(
          Theme.of(context).scaffoldBackgroundColor,
        ),
        appBar: SimpleAppBar(
          title: _title(t),
          actions: [
            // 设置入口：进入会话后可见；saved 后页面即将自动退出，隐藏。
            if (controller != null &&
                state != null &&
                state.phase != ResourceAiPhase.idle &&
                state.phase != ResourceAiPhase.saved)
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: t.resourceAi.settingsTitle,
                onPressed: () => showResourceAiSessionSettingsSheet(
                  context,
                  controller: controller,
                ),
              ),
          ],
        ),
        body: _bootError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 32, color: colors.error),
                      const SizedBox(height: 12),
                      Text(
                        t.resourceAi.bootFailed,
                        style:
                            SimpleTextStyles.title3.copyWith(color: colors.ink),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _bootError!,
                        style: SimpleTextStyles.caption
                            .copyWith(color: colors.muted),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {
                          setState(() => _bootError = null);
                          _boot();
                        },
                        child: Text(t.common.retry),
                      ),
                    ],
                  ),
                ),
              )
            : controller == null || state == null
                ? const Center(child: CircularProgressIndicator())
                : state.phase == ResourceAiPhase.idle
                    ? _ModelGate(controller: controller)
                    : Column(
                        children: [
                          if (state.phase == ResourceAiPhase.fatal &&
                              !_bannerDismissed)
                            _ErrorBanner(
                              message: errorText,
                              onRetry: () => _retryLast(controller),
                              onDismiss: () =>
                                  setState(() => _bannerDismissed = true),
                            ),
                          Expanded(
                            child: _MessageList(state: state, colors: colors),
                          ),
                          // 定稿横幅：agent 声明可交付，快捷完成入口。
                          if ((state.draft?.finalized ?? false) &&
                              state.phase == ResourceAiPhase.ready)
                            Material(
                              color: colors.surfaceVariant,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: SimpleSpacing.sLg,
                                  vertical: SimpleSpacing.sXs,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline,
                                      size: 16,
                                      color: colors.primary,
                                    ),
                                    const SizedBox(width: SimpleSpacing.s2xs),
                                    Expanded(
                                      child: Text(
                                        t.resourceAi.draftFinalizedBanner,
                                        style: SimpleTextStyles.caption,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => showResourceAiFinishFlow(
                                        context,
                                        controller: controller,
                                      ),
                                      child: Text(
                                        (controller.targetCardId != null ||
                                                controller.targetBookId != null)
                                            ? t.resourceAi.finishUpdate
                                            : t.resourceAi.finishCreate,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (busy)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: SimpleSpacing.s2xs,
                              ),
                              child: Center(
                                child: Text(
                                  t.resourceAi.generatingHint,
                                  style: SimpleTextStyles.caption
                                      .copyWith(color: colors.muted),
                                ),
                              ),
                            ),
                          _InputBar(
                            controller: _inputController,
                            busy: busy,
                            onSend: (text) {
                              _inputController.clear();
                              controller.send(text);
                            },
                            onCancel: controller.cancel,
                            onAttach: () => _attach(controller),
                          ),
                        ],
                      ),
      ),
    );
  }

  /// 结构化错误 → 本地化文案（kind 选模板，detail 为技术细节）。
  String _errorText(Translations t, ResourceAiError e) => switch (e.kind) {
        ResourceAiErrorKind.modelUnavailable =>
          t.resourceAi.errorModelUnavailable(detail: e.detail),
        ResourceAiErrorKind.turnIncomplete =>
          t.resourceAi.errorTurnIncomplete(detail: e.detail),
        ResourceAiErrorKind.saveFailed =>
          t.resourceAi.saveFailed(error: e.detail),
      };

  String _title(Translations t) {
    final editing = (widget.targetCardId ?? widget.targetBookId) != null;
    if (widget.kind == DraftKind.characterCard) {
      return editing
          ? t.resourceAi.editCardTitle
          : t.settings.resourceLibrary.aiCreateCard;
    }
    return editing
        ? t.resourceAi.editBookTitle
        : t.settings.resourceLibrary.aiCreateBook;
  }

  void _retryLast(ResourceAiController controller) {
    final userMsgs = controller.state.messages
        .where((m) => m.role == ResourceAiMessageRole.user)
        .toList();
    final last = userMsgs.isEmpty ? '' : userMsgs.last.text;
    if (last.isNotEmpty) {
      controller.send(last);
    }
  }

  Future<void> _attach(ResourceAiController controller) async {
    final t = Translations.of(context);
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path;
      if (path == null) return;
      final content = await readFileContentNative(path);
      if (content.length > ResourceImportService.maxImportBytes) {
        _snack(t.resourceAi.attachTooLarge);
        return;
      }
      controller.attachReference(content, picked.name);
      _snack(t.resourceAi.attached(name: picked.name));
    } catch (e) {
      _snack(t.resourceAi.attachFailed(error: '$e'));
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(message),
        ),
      );
  }

  Future<void> _confirmExit() async {
    final t = Translations.of(context);
    final leave = await showLmDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.resourceAi.exitConfirmTitle),
        content: Text(t.resourceAi.exitConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(t.resourceAi.exitAnyway),
          ),
        ],
      ),
    );
    if ((leave ?? false) && mounted) {
      // RA13-2：确认退出时取消在途生成轮——
      // 此前仅 pop，LLM 流在后台跑到自然结束继续耗 token，用户以为已中止。
      _controller?.cancel();
      Navigator.of(context).pop();
    }
  }
}

/// 未选模型的内联选择门：说明 + 换模型 + 开始。
///
/// 选中即经 controller.updateModel 持久化 override（快照哲学），start()
/// 随后直接以该快照进入 ready；门自身不持选择状态，从 controller.state 读。
class _ModelGate extends ConsumerStatefulWidget {
  const _ModelGate({required this.controller});

  final ResourceAiController controller;

  @override
  ConsumerState<_ModelGate> createState() => _ModelGateState();
}

class _ModelGateState extends ConsumerState<_ModelGate> {
  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final presetId = widget.controller.state.modelPresetId;
    final modelId = widget.controller.state.modelId;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: LmLayout.panelNarrowWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.all(SimpleSpacing.sXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.resourceAi.modelGateTitle,
                style: SimpleTextStyles.title2,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SimpleSpacing.sMd),
              Text(
                t.resourceAi.modelGateBody,
                style: SimpleTextStyles.body.copyWith(color: colors.muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SimpleSpacing.sLg),
              OutlinedButton.icon(
                icon: const Icon(Icons.tune_outlined),
                label: Text(
                  presetId == null
                      ? t.settings.chatSettings.defaultModel.select
                      : '$presetId / ${modelId ?? ''}',
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: _pickModel,
              ),
              const SizedBox(height: SimpleSpacing.sMd),
              FilledButton(
                onPressed: () => widget.controller.start(),
                child: Text(t.resourceAi.modelGateStart),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickModel() async {
    await showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DefaultModelPickerSheet(
        selectedPresetId: widget.controller.state.modelPresetId,
        selectedModelId: widget.controller.state.modelId,
        onModelSelected: (presetId, modelId) async {
          if (presetId != null && modelId != null) {
            await widget.controller.updateModel(
              presetId: presetId,
              modelId: modelId,
            );
          }
        },
      ),
    );
  }
}

/// 消息流：user 右对齐 / assistant 左对齐（markdown）/ material 元信息行 /
/// tool 过程线（本地化草稿变更文案）。
///
/// 自动跟随：视口在底部（120px 容差）时新消息到达自动滚到底；
/// 用户上翻查看历史时不打扰。
class _MessageList extends StatefulWidget {
  const _MessageList({required this.state, required this.colors});

  final ResourceAiState state;
  final LmPalette colors;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final _scrollController = ScrollController();
  bool _nearBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateNearBottom);
    if (widget.state.messages.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.messages.length > oldWidget.state.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_nearBottom || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: LmMotion.fast,
          curve: LmMotion.easeStandard,
        );
      });
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_updateNearBottom)
      ..dispose();
    super.dispose();
  }

  void _updateNearBottom() {
    if (!_scrollController.hasClients) return;
    final near = _scrollController.offset >=
        _scrollController.position.maxScrollExtent - 120;
    if (near != _nearBottom) {
      _nearBottom = near;
    }
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = widget.colors;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      itemCount: widget.state.messages.length,
      itemBuilder: (context, index) {
        final m = widget.state.messages[index];
        return switch (m.role) {
          ResourceAiMessageRole.user => Align(
              alignment: Alignment.centerRight,
              child: Container(
                margin: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sMd,
                  vertical: SimpleSpacing.sXs,
                ),
                decoration: BoxDecoration(
                  color: colors.primaryDim,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
                constraints: const BoxConstraints(
                  maxWidth: LmLayout.panelWidth,
                ),
                child: Text(m.text, style: SimpleTextStyles.body),
              ),
            ),
          ResourceAiMessageRole.assistant => Align(
              alignment: Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sMd,
                  vertical: SimpleSpacing.sXs,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceElevated,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
                constraints: const BoxConstraints(
                  maxWidth: LmLayout.panelWidth,
                ),
                child: SimpleMarkdownBody(data: m.text),
              ),
            ),
          ResourceAiMessageRole.material => Padding(
              padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
              child: Row(
                children: [
                  Icon(Icons.attach_file, size: 14, color: colors.muted),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Expanded(
                    child: Text(
                      m.name ?? '',
                      style: SimpleTextStyles.caption
                          .copyWith(color: colors.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ResourceAiMessageRole.tool => Padding(
              padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
              child: Align(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_note, size: 14, color: colors.muted),
                    const SizedBox(width: SimpleSpacing.s2xs),
                    Flexible(
                      child: Builder(
                        builder: (context) {
                          final change = m.change;
                          return Text(
                            change == null ? '' : draftChangeLabel(t, change),
                            style: SimpleTextStyles.caption
                                .copyWith(color: colors.muted),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        };
      },
    );
  }
}

/// 错误横幅：重发上一条 / 留在现场忽略。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Material(
      color: colors.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.sXs,
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: colors.error),
            const SizedBox(width: SimpleSpacing.s2xs),
            Expanded(
              child: Text(
                message,
                style: SimpleTextStyles.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: Text(t.resourceAi.retryLast),
            ),
            TextButton(
              onPressed: onDismiss,
              child: Text(t.resourceAi.dismissError),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部输入栏：附件 + 多行输入 + 发送/停止。
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.busy,
    required this.onSend,
    required this.onCancel,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool busy;
  final ValueChanged<String> onSend;
  final VoidCallback onCancel;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.sXs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: t.resourceAi.attach,
              icon: const Icon(Icons.attach_file_outlined),
              onPressed: busy ? null : onAttach,
            ),
            const SizedBox(width: SimpleSpacing.s2xs),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !busy,
                minLines: 1,
                maxLines: 6,
                onSubmitted: busy ? null : onSend,
                decoration: InputDecoration(
                  hintText: t.resourceAi.inputHint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sMd,
                    vertical: SimpleSpacing.sXs,
                  ),
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                    borderSide: BorderSide(color: colors.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                    borderSide: BorderSide(color: colors.divider),
                  ),
                ),
              ),
            ),
            const SizedBox(width: SimpleSpacing.s2xs),
            if (busy)
              IconButton.filled(
                tooltip: t.resourceAi.stop,
                icon: const Icon(Icons.stop),
                onPressed: onCancel,
              )
            else
              IconButton.filled(
                tooltip: t.resourceAi.send,
                icon: const Icon(Icons.send_outlined),
                onPressed: () {
                  final text = controller.text.trim();
                  if (text.isEmpty) return;
                  onSend(text);
                },
              ),
          ],
        ),
      ),
    );
  }
}
