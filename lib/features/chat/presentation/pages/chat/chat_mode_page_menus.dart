// part of ChatModePage，仅拆分用途，不引入新逻辑。
// 详见 chat_mode_page.dart 顶部说明。
//
// 拆分：extension 不是 State 子类，访问 `setState` 等 protected 成员
// 触发 invalid_use_of_protected_member。这是 part + extension 拆分方案
// 的固有约束，运行无误，文件级忽略（沿用 advanced_chat_controller 先例）。
// ignore_for_file: invalid_use_of_protected_member

part of 'chat_mode_page.dart';

/// 拆分到本 part 文件的菜单/弹窗/底部面板方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [_ChatModePageState] 类成员，
/// 可访问主文件中的私有字段（_tokenCount 等）。
extension _ChatModePageMenus on _ChatModePageState {
  /// 显示聊天菜单（对标 ChatBox 右上角菜单）
  void _showChatMenu(BuildContext context) {
    final t = Translations.of(context);
    final chatState = ref.read(chatModeControllerProvider(widget.session));
    // 手动压缩守卫与 compressHistory 同源（压缩/发送/流式中均
    /// busy 返回），此前菜单只查 isCompressing，流式中可点后静默 no-op
    final canCompress = !_isBusyForUserActions(chatState);
    showLmSheet<void>(
      context: context,
      // builder 参数命名为 sheetContext（菜单 BottomSheet 自己的 context），
      // 避免遮蔽外层 _showChatMenu 的 context（AppBar IconButton 的稳定 context）。
      // 关闭菜单必须用 sheetContext（pop 当前 route）；
      // 但导出 exportSession 必须用外层 context——菜单 pop 后 sheetContext 失效，
      // 用它弹格式选择 BottomSheet 会弹不出来（用户反馈"点击没反应"的根因）。
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.tune),
                title: Text(
                  t.chat.sessionSettings.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showSessionSettings();
                },
              ),
              ListTile(
                leading: const Icon(Icons.compress),
                title: Text(t.chat.compaction.manualTrigger),
                enabled: canCompress,
                onTap: canCompress
                    ? () {
                        Navigator.of(sheetContext).pop();
                        _handleCompressHistory();
                      }
                    : null,
              ),
              ListTile(
                // 批 K：会话内搜索入口
                leading: const Icon(Icons.search),
                title: Text(
                  t.chat.inSessionSearch.menuTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _toggleInSessionSearch();
                },
              ),
              ListTile(
                leading: const Icon(Icons.clear_all),
                title: Text(
                  t.chat.clearMessages,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // 清空消息与手动压缩同 busy 口径——此前常驻可点，
                // 先弹「不可恢复」确认再被 controller 守卫无声拦下
                enabled: canCompress,
                onTap: canCompress
                    ? () {
                        Navigator.of(sheetContext).pop();
                        _confirmClearMessages();
                      }
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: Text(t.settings.data.sessionExport.title),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  // 关键：用外层 context（IconButton 的稳定 context），不能用 sheetContext
                  // ——菜单已 pop，sheetContext 对应的 route 正在销毁，用它弹新 UI 会失败
                  // 2026-07-22 修复：用 controller.state.session.sessionId（物化后的真实 id），
                  // 而非 widget.session.sessionId（可能是 draft id）。物化后若用 draft id
                  // 导出，DB 查不到对应消息，导出空文件。
                  final realSessionId = ref
                      .read(chatModeControllerProvider(widget.session))
                      .session
                      .sessionId;
                  exportSession(
                    context,
                    ref,
                    realSessionId,
                    sessionTitle: ref
                        .read(chatModeControllerProvider(widget.session))
                        .session
                        .title,
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: sheetContext.lm.palette.error,
                ),
                title: Text(
                  t.chat.deleteSessionFromChat,
                  style: TextStyle(
                    color: sheetContext.lm.palette.error,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmDeleteSession();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 手动压缩上下文
  ///
  /// 流式压缩过程中摘要卡片实时打字，失败时显示常驻失败卡片。
  /// 压缩成功后弹窗询问是否用新摘要更新会话标题。
  Future<void> _handleCompressHistory() async {
    final t = Translations.of(context);
    final controller =
        ref.read(chatModeControllerProvider(widget.session).notifier);
    final messenger = ScaffoldMessenger.of(context);

    final result = await controller.compressHistory();

    if (!mounted) return;
    switch (result) {
      case CompressResult.success:
        // 弹窗询问是否用新摘要更新会话标题
        final shouldUpdateTitle = await showLmDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              t.chat.compaction.updateTitleQuestion,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(t.chat.compaction.updateTitleCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(t.chat.compaction.updateTitleConfirm),
              ),
            ],
          ),
        );
        if ((shouldUpdateTitle ?? false) && mounted) {
          await controller.updateTitleFromSummary(force: true);
        }
      case CompressResult.busy:
        // 菜单入口已按同源守卫禁用；此处兜底（如 ContextUsage
        // 详情面板的入口在打开后进入生成态）——不再静默 no-op
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.chat.failure.busyOperation),
            duration: const Duration(seconds: 2),
          ),
        );
      case CompressResult.insufficient:
        // 消息不足≠压缩失败——专属文案，不再误导
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.chat.compaction.insufficient),
            duration: const Duration(seconds: 2),
          ),
        );
      case CompressResult.failed:
        // 失败卡片已作为常驻消息插入对话流，无需额外提示
        break;
      case CompressResult.cancelled:
        // 用户主动停止——占位摘要已清理，静默即可
        break;
    }
  }

  // ── 上下文用量圆环详情面板（与故事/导演同款）─────────────────

  /// 上下文用量详情面板（sheet 内 Consumer watch，压缩态实时刷新）。
  ///
  /// 数据口径与旧 token 徽章同源：已用 = 最近一次落库 tokensUsed +
  /// 草稿输入 token；满刻度 = chat 压缩触发线（availableWindow × 阈值）。
  /// 输出/缓存读取行消费最近一轮 usage 分项（控制器流式完成时留存），
  /// 缺失时「—」+ 面板口径脚注；chat 的输入行是本地口径（tokensUsed
  /// 为 totalTokens），命中率不做会话累计，恒「—」。
  /// 手动压缩复用 [_handleCompressHistory]（CompressResult 分态：成功弹
  /// 标题更新询问 / insufficient 专属文案 / 失败常驻卡片）。
  void _showContextUsageSheet() {
    unawaited(
      showLmSheet<void>(
        context: context,
        // 面板自限 0.9 屏高 + 内部滚动兜底（与故事/导演接线一致）
        isScrollControlled: true,
        builder: (sheetContext) => Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(chatModeControllerProvider(widget.session));
            return ContextUsageDetailSheet(
              contextWindowTokens: state.contextWindowTokens,
              compactionTriggerTokens: state.compactionTriggerTokens,
              lastPromptTokens:
                  _lastContextTokens(state.messages) + _tokenCount,
              // 最近一轮输出/缓存读分项（ 上一轮完成后随 usage 留 state；
              // null = 端点未回 usage / 重进会话未重新生成 →「—」+ 脚注）
              lastCompletionTokens: state.lastCompletionTokens,
              lastCacheReadTokens: state.lastCacheReadTokens,
              averageCacheHit: null,
              // 轮次口径走共享公式（nextTurn 计数器权威，NULL 回退推导）
              sessionRounds: resolveTurnNumber(
                    nextTurn: state.session.nextTurn,
                    compactedTurnBase: 0,
                    messages: state.messages,
                  ) -
                  1,
              // chat 压缩流式打字进对话流的摘要卡，不进本面板
              isManualCompacting: state.isCompressing,
              manualCompactionDelta: '',
              manualCompactionError: null,
              //  同款：请求/流式/思考进行中按钮置灰
              isRoundActive:
                  state.isSending || state.isStreaming || state.isThinking,
              onManualCompact: () {
                Navigator.of(sheetContext).pop();
                unawaited(_handleCompressHistory());
              },
            );
          },
        ),
      ),
    );
  }

  /// 显示模型选择面板（轻量级，对标 ChatBox 模型快速切换）
  //
  // 2026-07-24 双菜单→单菜单改造：
  // 原实现打开 ModelSelectorSheet（双 dropdown：供应商 + 模型），
  // 现直接复用 DefaultModelPickerSheet（按供应商分组的单菜单 + 折叠），
  // 与会话设置 sheet / 标题模型 picker 保持一致体验。
  // 持久化路径不变：通过 controller.updateSession 写入会话级 presetId/modelId。
  void _showModelSelector() {
    final session =
        ref.read(chatModeControllerProvider(widget.session)).session;
    final controller =
        ref.read(chatModeControllerProvider(widget.session).notifier);
    final t = Translations.of(context);
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DefaultModelPickerSheet(
          selectedPresetId: session.presetId,
          selectedModelId: session.modelId,
          title: t.chat.modelSelector.title,
          successMessage: t.chat.sessionSettings.modelSelected,
          clearLabel: t.chat.sessionSettings.resetToGlobal,
          clearSuccessMessage: t.chat.sessionSettings.modelCleared,
          onModelSelected: (presetId, modelId) async {
            // 清除=写全局当前快照，不再置 null 跟随态
            if (presetId == null && modelId == null) {
              final snapshot = await ref
                  .read(configurationResolverProvider)
                  .snapshotSimpleDefaults();
              await controller.updateSession(
                session.copyWith(
                  presetId: snapshot.presetId ?? session.presetId,
                  modelId: snapshot.modelId ?? session.modelId,
                ),
              );
              return;
            }
            await controller.updateSession(
              session.copyWith(presetId: presetId, modelId: modelId),
            );
          },
        );
      },
    );
  }

  /// 显示会话设置面板（对标 ChatBox SessionSettingsModal）
  ///
  /// 2026-07-28 修复：传递 `widget.session`（原始草稿 key）而非
  /// `controller.state.session`（物化后的真实会话）。
  ///
  /// 原代码读取物化后的真实 session 传给 SessionSettingsSheet，但 sheet 内部
  /// 用 `widget.session` 作为 family provider key 查找 controller。当 sessionId
  /// 从 `__draft_xxx` 变成真实 uuid 后，sheet 会查到一个**新的 controller 实例**，
  /// 与聊天页面用的草稿 controller 状态隔离，导致"输入框切换模型后 sheet 显示不同步"。
  ///
  /// 修复后：sheet 拿到的是原始草稿 key，查找的 controller 与聊天页面同一个，
  /// state 自动同步。sheet 内部仍会通过 `ref.read(...).session` 读取最新真实 session
  /// 数据用于显示，但 controller 实例保持一致。
  void _showSessionSettings() {
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      // 内容自绘 Handle。
      glassHandle: false,
      builder: (context) {
        return SessionSettingsSheet(
          session: widget.session,
          // 2026-07-22 修复：sheet 内部已通过 controller.updateSession 持久化，
          // 这里不再重复调用，避免草稿物化逻辑被触发两次。
          // onSessionUpdated 仅用于通知调用方（如有 UI 刷新需求）。
          onSessionUpdated: (_) {},
          onSessionDeleted: () {
            Navigator.of(context).pop();
            widget.onSessionDeleted?.call();
          },
        );
      },
    );
  }

  /// 确认清空消息
  void _confirmClearMessages() {
    final t = Translations.of(context);
    showLmDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(t.chat.clearMessages),
          content: Text(t.chat.clearMessagesConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                // controller 守卫静默 return 的前置反馈——确认
                // 弹窗后的无声失败最伤信任（菜单已联动禁用，此处兜底
                // 确认弹窗打开期间进入生成态的窗口）
                if (_isBusyForUserActions(
                  ref.read(chatModeControllerProvider(widget.session)),
                )) {
                  _showBusyHint();
                  return;
                }
                ref
                    .read(chatModeControllerProvider(widget.session).notifier)
                    .clearMessages();
              },
              child: Text(t.common.confirm),
            ),
          ],
        );
      },
    );
  }

  /// 确认删除会话
  ///
  /// 此前确认按钮只做导航不删库（假删除）——
  /// 用户确认「此操作不可恢复」后会话原封不动。现在真正执行
  /// deleteSession 后再回主页；草稿会话未入库则直接导航。
  void _confirmDeleteSession() {
    final t = Translations.of(context);
    showLmDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            t.chat.deleteSessionFromChat,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: Text(
            t.chat.deleteSessionFromChatConfirm,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                // 读取 provider 当前值（ChatModeState），不经 notifier.state
                final state =
                    ref.read(chatModeControllerProvider(widget.session));
                // 生成中禁删：流式仍持有该会话 controller，删除后继续
                // 写入会向已删会话回写孤儿数据（与侧边栏同口径）
                if (state.isSending ||
                    state.isStreaming ||
                    state.isCompressing) {
                  ScaffoldMessenger.of(this.context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(
                          t.chat.failure.deleteBlockedWhileGenerating,
                        ),
                      ),
                    );
                  return;
                }
                final sessionId = state.session.sessionId;
                if (!sessionId
                    .startsWith(ChatModeController.draftSessionIdPrefix)) {
                  final chatRepo =
                      ref.read<ChatRepository>(chatRepositoryProvider);
                  await chatRepo.deleteSession(sessionId);
                  // 删除即清（invalidate 等值实例即命中
                  // family 键），随后的导航离开自然重建/不再重建
                  ref.invalidate(chatModeControllerProvider(widget.session));
                }
                widget.onSessionDeleted?.call();
              },
              child: Text(t.common.confirm),
            ),
          ],
        );
      },
    );
  }
}
