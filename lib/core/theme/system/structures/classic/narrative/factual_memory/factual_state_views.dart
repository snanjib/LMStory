import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _buildEmptyState / _buildErrorState，
// 逐字符搬运）。

/// 事实列表空态（原 _FactualMemoryTabState._buildEmptyState）。
class FactualEmptyStateView extends StatelessWidget {
  const FactualEmptyStateView({
    required this.colors,
    required this.t,
    required this.searchQuery,
    super.key,
  });

  final LmPalette colors;
  final Translations t;

  /// 当前搜索词（区分"无实体"与"无搜索结果"文案）
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    // 居中布局防护（项目规则 §9/§10）：本 tab 含搜索框（TextField），
    // 键盘弹出时 Expanded 可视高度减少 30%-50%，裸 Center+Column 会溢出。
    // 使用 LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight) 模式。
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(LmSpacing.sXl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    searchQuery.isEmpty
                        ? Icons.account_tree_outlined
                        : Icons.search_off,
                    size: 48,
                    color: colors.faint,
                  ),
                  const SizedBox(height: LmSpacing.sMd),
                  Text(
                    searchQuery.isEmpty
                        ? t.intermediate.memoryBrowser.factEmpty
                        : t.intermediate.memoryBrowser.searchEmpty,
                    style: LmNarrativeTextStyles.bodyUi.copyWith(
                      color: colors.muted,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 加载失败错误态（原 _FactualMemoryTabState._buildErrorState）。
class FactualErrorStateView extends StatelessWidget {
  const FactualErrorStateView({
    required this.colors,
    required this.t,
    required this.message,
    required this.onRetry,
    super.key,
  });

  final LmPalette colors;
  final Translations t;
  final String message;

  /// 重试（原 onPressed: _loadData）
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // 居中布局防护（项目规则 §9/§10）：同 FactualEmptyStateView。
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(LmSpacing.sXl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: colors.error),
                  const SizedBox(height: LmSpacing.sMd),
                  Text(
                    message,
                    style: LmNarrativeTextStyles.bodyUi.copyWith(
                      color: colors.ink,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: LmSpacing.sMd),
                  OutlinedButton(
                    onPressed: onRetry,
                    child: Text(
                      t.common.retry,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
