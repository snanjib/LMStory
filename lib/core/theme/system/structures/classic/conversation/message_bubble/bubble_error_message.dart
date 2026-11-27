import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/utils/secret_redactor.dart';
import 'package:lmstory/features/chat/domain/services/simple_failure_classifier.dart';
import 'package:lmstory/i18n/strings.g.dart';

// =============================================================================
// Error message (persisted in message)
// （从 simple_message_bubble.dart 拆出，内容区引用）
// =============================================================================

/// Displays a persisted error message inside the assistant bubble.
///
/// Reference: ChatBox's error display — errors are stored as part of the
/// message and remain visible when switching conversation branches.
/// Style: error icon + error text on a subtle error-tinted background.
///
/// 结构化错误直接显示摘要和建议。旧格式保留三行预览与展开操作，
/// 技术详情保持独立折叠。
///
/// 识别 errorText 中的 `\n建议：` 分隔符，
/// 将建议行单独渲染（lightbulb 图标 + error 色），其余文本作为错误描述。
/// 向后兼容：无 `\n建议：` 分隔符时按原逻辑渲染整个 errorText。
class BubbleErrorMessage extends StatefulWidget {
  const BubbleErrorMessage({
    required this.errorText,
    required this.colors,
    super.key,
  });

  final String errorText;
  final LmPalette colors;

  @override
  State<BubbleErrorMessage> createState() => _BubbleErrorMessageState();
}

class _BubbleErrorMessageState extends State<BubbleErrorMessage> {
  bool _isExpanded = false;
  // 2026-07-29：详细信息折叠状态（独立于错误描述的展开/收起）
  bool _isDetailExpanded = false;

  /// 识别 `\n建议：` 分隔符，拆分为 (错误描述, 建议内容)。
  /// 2026-07-29：同时识别 `\n详细信息：` 分隔符，拆出原始错误信息。
  /// 无分隔符时对应字段为 null，向后兼容。
  ///
  /// 新写入为 `lmerr:` JSON 前缀（SimpleErrorPayload），
  /// 先试结构化解码（locale 无关）；失败回退下方旧分隔符解析（存量兼容，
  /// 分隔符字面量仅为旧格式保留）。
  ({
    String errorPart,
    String? suggestion,
    String? detail,
    bool structured,
  }) _parseErrorText() {
    final text = widget.errorText;
    final payload = SimpleErrorPayload.tryDecode(text);
    if (payload != null) {
      final code = payload.code;
      final labels = Translations.of(context).chat.failure;
      final errorPart = code == null || code.isEmpty
          ? payload.message
          : labels.displayFormat(message: payload.message, code: code);
      return (
        errorPart: errorPart,
        structured: true,
        suggestion: payload.suggestion == null || payload.suggestion!.isEmpty
            ? null
            : payload.suggestion,
        detail: payload.detail == null || payload.detail!.isEmpty
            ? null
            : payload.detail,
      );
    }
    if (text.startsWith(SimpleErrorPayload.prefix)) {
      return (
        errorPart: Translations.of(context).chat.failure.messages.unknown,
        structured: true,
        suggestion: null,
        detail: null,
      );
    }
    // 先拆出详细信息（格式：...\n详细信息：$detail）
    final detailIdx = text.indexOf(SimpleErrorPayload.legacyDetailSeparator);
    var remaining = text;
    String? detail;
    if (detailIdx != -1) {
      remaining = text.substring(0, detailIdx);
      detail = text.substring(
        detailIdx + SimpleErrorPayload.legacyDetailSeparator.length,
      );
    }
    // 再从剩余部分拆出建议（格式：...\n建议：$suggestion）
    // i18n 中 displayFormatWithSuggestion 使用 `\n$suggestionLabel：` 分隔
    // suggestionLabel 默认为 "建议"，因此分隔符为 `\n建议：`
    final idx = remaining.indexOf(SimpleErrorPayload.legacySuggestionSeparator);
    if (idx == -1) {
      return (
        errorPart: remaining,
        suggestion: null,
        detail: detail,
        structured: false,
      );
    }
    final errorPart = remaining.substring(0, idx);
    final suggestion = remaining.substring(
      idx + SimpleErrorPayload.legacySuggestionSeparator.length,
    );
    return (
      errorPart: errorPart,
      suggestion: suggestion,
      detail: detail,
      structured: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final parsed = _parseErrorText();
    final suggestion = parsed.suggestion;
    final showFullSummary = parsed.structured || _isExpanded;
    final hasDetail = parsed.detail != null && parsed.detail!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(top: LmSpacing.sXs),
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: widget.colors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(
          color: widget.colors.error.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                size: 16,
                color: widget.colors.error,
              ),
              const SizedBox(width: LmSpacing.sXs),
              Expanded(
                child: Text(
                  parsed.errorPart,
                  style: LmUiTextStyles.bodySm.copyWith(
                    color: widget.colors.error,
                  ),
                  maxLines: showFullSummary ? null : 3,
                  overflow: showFullSummary
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (suggestion != null) ...[
            const SizedBox(height: LmSpacing.sXs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!parsed.structured) ...[
                  Icon(
                    Icons.lightbulb_outline,
                    size: 16,
                    color: widget.colors.error,
                  ),
                  const SizedBox(width: LmSpacing.sXs),
                ],
                Expanded(
                  child: Text(
                    parsed.structured
                        ? suggestion
                        : '${t.chat.failure.suggestionLabel}：$suggestion',
                    style: LmUiTextStyles.bodySm.copyWith(
                      color: widget.colors.error,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
          // 2026-07-29：详细信息行（可折叠，默认折叠）
          // 显示供应商返回的原始错误信息，帮助用户定位 400 参数错误等具体原因
          if (hasDetail) ...[
            const SizedBox(height: LmSpacing.sXs),
            GestureDetector(
              onTap: () =>
                  setState(() => _isDetailExpanded = !_isDetailExpanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isDetailExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.chevron_right,
                    size: 16,
                    color: widget.colors.error.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: LmSpacing.s2xs),
                  Text(
                    t.chat.failure.detailLabel,
                    style: LmUiTextStyles.bodySm.copyWith(
                      color: widget.colors.error.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (_isDetailExpanded) ...[
              const SizedBox(height: LmSpacing.s2xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: LmSpacing.sSm,
                  vertical: LmSpacing.sXs,
                ),
                decoration: BoxDecoration(
                  color: widget.colors.error.withValues(alpha: 0.05),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
                child: SelectableText(
                  redactDiagnosticText(parsed.detail!),
                  style: LmUiTextStyles.bodySm.copyWith(
                    color: widget.colors.error.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
          if (!parsed.structured)
            Align(
              alignment: Alignment.centerRight,
              child: _ErrorToggleButton(
                isExpanded: _isExpanded,
                colors: widget.colors,
                expandLabel: t.chat.messageActions.showMore,
                collapseLabel: t.chat.messageActions.showLess,
                onTap: () => setState(() => _isExpanded = !_isExpanded),
              ),
            ),
        ],
      ),
    );
  }
}

/// 错误卡片的展开/收起切换按钮。
///
/// 紧凑型 TextButton，文字 + 上下箭头图标。颜色用 error 色保持视觉一致性。
class _ErrorToggleButton extends StatelessWidget {
  const _ErrorToggleButton({
    required this.isExpanded,
    required this.colors,
    required this.expandLabel,
    required this.collapseLabel,
    required this.onTap,
  });

  final bool isExpanded;
  final LmPalette colors;
  final String expandLabel;
  final String collapseLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.s2xs,
          vertical: LmSpacing.s3xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isExpanded ? collapseLabel : expandLabel,
              style: LmUiTextStyles.overline.copyWith(
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: LmSpacing.s3xs),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 14,
              color: colors.error,
            ),
          ],
        ),
      ),
    );
  }
}
