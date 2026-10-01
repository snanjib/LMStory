import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 日志查看器组件（诊断页）
///
/// 渲染 FileLogSink 落盘的日志 tail，等宽字体 + 按级别着色。
///
/// 着色规则（对比度 ≥4.5:1）：
/// - DEBUG → faint（灰，低优先级调试信息）
/// - INFO  → muted（默认，常规运行信息）
/// - WARN  → warning（琥珀，需关注）
/// - ERROR → error（红，故障）
///
/// 视觉：固定高度容器 + 内部纵向滚动，避免日志过多撑爆诊断页。
class LogViewer extends StatelessWidget {
  const LogViewer({
    required this.lines,
    required this.onShare,
    super.key,
  });

  /// 日志行（已 tail 截断，按时间正序，最旧在上）
  final List<String> lines;

  /// 分享日志文件回调
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行：标题 + 分享按钮
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.settings.diagnostics.logs.title,
                      style: SimpleTextStyles.title3.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.settings.diagnostics.logs.desc,
                      style: SimpleTextStyles.caption
                          .copyWith(color: colors.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _ShareButton(onTap: onShare),
            ],
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          // 日志内容
          Expanded(child: _buildContent(context, colors)),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, LmPalette colors) {
    final t = Translations.of(context);

    if (lines.isEmpty) {
      return _EmptyState(
        icon: Icons.description_outlined,
        message: t.settings.diagnostics.logs.empty,
        colors: colors,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.sXs,
      ),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final line = lines[index];
          final levelColor = _colorForLine(line, colors);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              line,
              // 字体策略：保留 fontFamily: 'monospace' 让英文/数字/时间戳等宽对齐，
              // 但移除原 fontFamilyFallback: ['RobotoMono', 'Courier New']——这俩字体
              // 不含中文字形，且会拦截 Flutter 内置中文 fallback，导致中文显示为方块。
              // 不指定 fallback 时 Flutter 会自动用系统字体兜底中文。
              // 修复「日志全是方块字符」问题。
              softWrap: true,
              style: SimpleTextStyles.caption.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
                color: levelColor,
                fontSize: 11,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 根据日志行的级别标记着色
  ///
  /// LogRecord.toLine 格式：`... [LEVEL] [LoggerName] message`
  Color _colorForLine(String line, LmPalette colors) {
    // 优先匹配更严重的级别（ERROR 行可能含 [INFO] 文本）
    if (line.contains('[ERROR]')) return colors.error;
    if (line.contains('[WARN]')) return colors.warning;
    if (line.contains('[DEBUG]')) return colors.faint;
    // INFO 和无级别标记的用 muted
    return colors.muted;
  }
}

class _ShareButton extends StatelessWidget {
  const _ShareButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sSm,
            vertical: SimpleSpacing.sXs,
          ),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.08),
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.ios_share, size: 16, color: colors.primary),
              const SizedBox(width: SimpleSpacing.s2xs),
              Flexible(
                child: Text(
                  t.settings.diagnostics.logs.share,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.message,
    required this.colors,
  });

  final IconData icon;
  final String message;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: colors.faint),
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            message,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
