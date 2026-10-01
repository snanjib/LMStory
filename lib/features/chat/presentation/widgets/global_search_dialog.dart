import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/search_highlight.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// ChatBox-style global search dialog (Ctrl+K equivalent).
///
/// Searches across all sessions' messages and displays results
/// grouped by session with highlighted search terms.
class GlobalSearchDialog extends ConsumerStatefulWidget {
  const GlobalSearchDialog({
    required this.onResultSelected,
    super.key,
  });

  /// Called when user taps (or Enter-selects) a search result.
  /// 携带完整结果（含 messageId），会话页可定位到命中消息。
  final ValueChanged<SearchResult> onResultSelected;

  @override
  ConsumerState<GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends ConsumerState<GlobalSearchDialog> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  Timer? _debounceTimer;

  List<SearchResult> _results = [];
  bool _isSearching = false;
  String _query = '';
  String? _errorMessage;

  /// 键盘高亮结果序号（：↑↓ 移动、Enter 打开）。
  int? _highlightedIndex;
  final _itemKeys = <int, GlobalKey>{};

  /// 请求序号守卫：连续输入时先发的慢查询晚返回，
  /// 若无守卫会覆盖新结果。
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _moveHighlight(int delta) {
    if (_results.isEmpty) return;
    final current = _highlightedIndex ?? 0;
    final next = (current + delta).clamp(0, _results.length - 1);
    setState(() => _highlightedIndex = next);
    _ensureHighlightVisible(next);
  }

  void _ensureHighlightVisible(int index) {
    final key = _itemKeys[index];
    final itemContext = key?.currentContext;
    if (itemContext != null) {
      Scrollable.ensureVisible(
        itemContext,
        duration: LmMotion.micro,
      );
    }
  }

  /// Enter：有键盘高亮（或存在结果）时直接打开该结果，否则立即搜索。
  void _onSubmitted(String value) {
    if (_results.isNotEmpty) {
      final index = (_highlightedIndex ?? 0).clamp(0, _results.length - 1);
      final result = _results[index];
      setState(() => _highlightedIndex = index);
      widget.onResultSelected(result);
      return;
    }
    _debounceTimer?.cancel();
    _performSearch(value);
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) {
      _requestSeq++;
      setState(() {
        _results = [];
        _query = '';
        _highlightedIndex = null;
        _isSearching = false;
        _errorMessage = null;
      });
      return;
    }

    final seq = ++_requestSeq;
    _itemKeys.clear();
    setState(() {
      _isSearching = true;
      _query = query.trim();
      _errorMessage = null;
    });

    try {
      final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
      final results = await chatRepo.searchMessages(query.trim());

      // 仅最新请求可落地，过期响应直接丢弃。
      if (mounted && seq == _requestSeq) {
        setState(() {
          _results = results;
          _isSearching = false;
          _highlightedIndex = results.isEmpty ? null : 0;
        });
      }
    } catch (e) {
      // 捕获异常，避免 _isSearching 永远为 true 导致一直转圈。
      // 原始异常串不进 UI（DB/内部路径细节），
      // 细节留在 debugPrint，界面走既有友好错误文案
      debugPrint('Global search failed: $e');
      if (mounted && seq == _requestSeq) {
        setState(() {
          _results = [];
          _isSearching = false;
          _highlightedIndex = null;
          _errorMessage = Translations.of(context).chat.globalSearch.error;
        });
      }
    }
  }

  /// Group results by session
  Map<String, List<SearchResult>> get _groupedResults {
    final groups = <String, List<SearchResult>>{};
    for (final result in _results) {
      groups.putIfAbsent(result.sessionId, () => []).add(result);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: LmShortcutHost(
        // ↑↓ 移动键盘高亮（焦点在输入框时单行 TextField
        // 不消费上下键，事件冒泡至此）。Esc 关闭浮层不在这里重复绑定——
        // 统一浮层入口（`showLmDialog`）已按 `barrierDismissible` 装好
        // `LmShortcuts.idOverlayDismiss`，本层再装一遍只是重复。
        scope: LmShortcutScope.overlay,
        autofocus: false,
        handlers: {
          LmShortcuts.idOverlayNext: () => _moveHighlight(1),
          LmShortcuts.idOverlayPrev: () => _moveHighlight(-1),
        },
        child: SizedBox(
          width: LmLayout.panelWidth,
          height: 480,
          child: Column(
            children: [
              // Search input
              _buildSearchInput(t, colors),
              Divider(height: 1, thickness: 1, color: colors.divider),
              // Results
              Expanded(child: _buildResults(t, colors)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchInput(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      child: TextField(
        controller: _searchController,
        focusNode: _focusNode,
        style: SimpleTextStyles.body.copyWith(color: colors.ink),
        decoration: InputDecoration(
          hintText: t.chat.globalSearch.hint,
          hintStyle: SimpleTextStyles.body.copyWith(color: colors.faint),
          prefixIcon: Icon(Icons.search, size: 20, color: colors.muted),
          suffixIcon: _searchController.text.isNotEmpty
              ? Semantics(
                  button: true,
                  label: t.common.clear,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      // 清除时取消防抖——
                      // 此前挂起的 500ms 定时器仍会用旧关键词回填结果，
                      // 「清空后又跳出旧结果」的幽灵回显。
                      _debounceTimer?.cancel();
                      _searchController.clear();
                      setState(() {
                        _results = [];
                        _query = '';
                      });
                    },
                    // 垫到 44px 触控目标
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.clear, size: 18, color: colors.muted),
                    ),
                  ),
                )
              : null,
          filled: true,
          fillColor: colors.surfaceElevated,
          border: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            vertical: SimpleSpacing.sSm,
          ),
          isDense: true,
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: _onSubmitted,
        onChanged: (value) {
          setState(() {});
          // Debounce: search after 500ms of inactivity
          _debounceTimer?.cancel();
          _debounceTimer = Timer(const Duration(milliseconds: 500), () {
            // lm-motion-exempt: 搜索去抖（交互节流，非过渡动效）
            if (mounted) {
              _performSearch(value);
            }
          });
        },
      ),
    );
  }

  Widget _buildResults(Translations t, LmPalette colors) {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 32, color: colors.error),
              const SizedBox(height: SimpleSpacing.sSm),
              Text(
                t.chat.globalSearch.error,
                style: SimpleTextStyles.bodySm.copyWith(color: colors.error),
              ),
              // 不再重复渲染 _errorMessage——它与标题
              // 是同一份友好文案，上下两行复读；原始异常细节走 debugPrint。
            ],
          ),
        ),
      );
    }

    if (_query.isEmpty) {
      return Center(
        child: Text(
          t.chat.globalSearch.hint,
          style: SimpleTextStyles.caption.copyWith(color: colors.faint),
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Text(
          t.chat.globalSearch.noResults,
          style: SimpleTextStyles.caption.copyWith(color: colors.faint),
        ),
      );
    }

    final groups = _groupedResults;
    // 预计算每组起始全局
    // 序号——ListView.builder 惰性执行 itemBuilder，闭包内累加 flatIndex
    // 在滚动后重建时归零重算，只有可见区 group 被 build，groupStartIndex
    // 错位（高亮/Enter 打开与屏幕条目不是同一条；错序 GlobalKey 永久滞留）。
    // 纯 index 函数在惰性重建下稳定。
    final groupIds = groups.keys.toList();
    final groupStarts = <int>[];
    var total = 0;
    for (final id in groupIds) {
      groupStarts.add(total);
      total += groups[id]!.length;
    }

    // 命中数达 SQL LIMIT 时提示结果可能不完整
    final truncated = _results.length >= ChatRepository.globalSearchLimit;

    return Column(
      children: [
        if (truncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SimpleSpacing.sMd,
              SimpleSpacing.s2xs,
              SimpleSpacing.sMd,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                t.chat.globalSearch.truncated(
                  n: ChatRepository.globalSearchLimit,
                ),
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final sessionId = groupIds[index];
              final sessionResults = groups[sessionId]!;
              final sessionName = sessionResults.first.sessionName;
              final groupStartIndex = groupStarts[index];

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Session header
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SimpleSpacing.sMd,
                      vertical: SimpleSpacing.s2xs,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 14,
                          color: colors.muted,
                        ),
                        const SizedBox(width: SimpleSpacing.s2xs),
                        Expanded(
                          child: Text(
                            sessionName,
                            style: SimpleTextStyles.caption.copyWith(
                              color: colors.muted,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: SimpleSpacing.s2xs),
                        Text(
                          '${sessionResults.length}',
                          style: SimpleTextStyles.caption.copyWith(
                            color: colors.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Message results for this session
                  for (var i = 0; i < sessionResults.length; i++)
                    _SearchResultItem(
                      key: _itemKeys[groupStartIndex + i] ??= GlobalKey(),
                      result: sessionResults[i],
                      query: _query,
                      colors: colors,
                      highlighted: _highlightedIndex == groupStartIndex + i,
                      onTap: () => widget.onResultSelected(sessionResults[i]),
                    ),
                  if (index < groups.length - 1)
                    Divider(
                      height: SimpleSpacing.sSm,
                      thickness: 1,
                      color: colors.divider,
                      indent: SimpleSpacing.sMd,
                      endIndent: SimpleSpacing.sMd,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Single search result item with highlighted query text.
class _SearchResultItem extends StatelessWidget {
  const _SearchResultItem({
    required this.result,
    required this.query,
    required this.colors,
    required this.onTap,
    this.highlighted = false,
    super.key,
  });

  final SearchResult result;
  final String query;
  final LmPalette colors;
  final VoidCallback onTap;

  /// 键盘导航高亮态。
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: highlighted ? colors.primaryDim : null,
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sMd,
          vertical: SimpleSpacing.s2xs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              result.role == 'user' ? Icons.person : Icons.smart_toy_outlined,
              size: 14,
              color: result.role == 'user' ? colors.primary : colors.muted,
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHighlightedContent(),
                  const SizedBox(height: 2),
                  Text(
                    _formatTime(context, result.createdAt),
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.faint,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightedContent() {
    final content = result.content;
    // 2026-09-08 修复：预览片段不再以 120 字符为界——短多行消息（关键字
    // 在第 3 行之后）被 maxLines 截断时关键字完全不显示。统一先定位
    // 关键字，围绕首命中截取上下文（关键字必含于片段）。
    final idx = findQueryIndex(content, query);
    if (idx >= 0) {
      return _buildRichText(
        buildContextSnippet(content, idx, query.length),
      );
    }
    // 极端情况：SQL LIKE 命中但 Dart 无法定位关键字
    // （Unicode 大小写折叠差异，如全角/半角、特殊 locale 折叠）
    // 展示完整内容由 maxLines 截断，避免仅显示前 120 字误导用户
    return _buildRichText(content);
  }

  Widget _buildRichText(String text) {
    return RichText(
      text: buildSearchHighlightSpans(
        text: text,
        query: query,
        baseStyle: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
        highlightStyle: SimpleTextStyles.bodySm.copyWith(
          color: colors.primary,
          fontWeight: FontWeight.w600,
          backgroundColor: colors.primaryDim,
        ),
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _formatTime(BuildContext context, DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    final t = Translations.of(context);

    if (diff.inMinutes < 1) return t.chat.time.justNow;
    if (diff.inMinutes < 60) {
      return t.chat.time.minutesAgo(n: diff.inMinutes);
    }
    if (diff.inHours < 24) {
      return t.chat.time.hoursAgo(n: diff.inHours);
    }
    if (diff.inDays < 30) {
      return t.chat.time.daysAgo(n: diff.inDays);
    }
    return '${time.month}/${time.day}';
  }
}
