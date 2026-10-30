import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 版本更新记录示意图（2026-07-27 新增）。
///
/// 用于「版本更新记录」wiki 页顶部主视觉。
///
/// 设计：
/// - 3 个版本阶段卡片纵向排列，按状态着色
/// - 每个卡片含版本号 + 状态 + schemaVersion + 描述
class VersionHistoryDiagram extends StatelessWidget {
  const VersionHistoryDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _VersionCard(
            title: t.help.versionHistory.diagramV01Title,
            status: t.help.versionHistory.v01Status,
            statusDesc: t.help.versionHistory.v01StatusDesc,
            schema: t.help.versionHistory.v01Schema,
            schemaDesc: t.help.versionHistory.v01SchemaDesc,
            statusColor: colors.success,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _VersionCard(
            title: t.help.versionHistory.diagramV02Title,
            status: t.help.versionHistory.v02Status,
            statusDesc: t.help.versionHistory.v02StatusDesc,
            schema: t.help.versionHistory.v02Schema,
            schemaDesc: t.help.versionHistory.v02SchemaDesc,
            statusColor: colors.warning,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _VersionCard(
            title: t.help.versionHistory.diagramV03Title,
            status: t.help.versionHistory.v03Status,
            statusDesc: t.help.versionHistory.v03StatusDesc,
            schema: t.help.versionHistory.v03Schema(
              // 上界从代码真源注入（drift schemaVersion），文案不手写数字
              schemaVersion: AppDatabase.currentSchemaVersion,
            ),
            schemaDesc: t.help.versionHistory.v03SchemaDesc,
            statusColor: colors.muted,
          ),
        ],
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.title,
    required this.status,
    required this.statusDesc,
    required this.schema,
    required this.schemaDesc,
    required this.statusColor,
  });

  final String title;
  final String status;
  final String statusDesc;
  final String schema;
  final String schemaDesc;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                RichText(
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                      fontSize: 11,
                      height: 1.4,
                    ),
                    children: [
                      TextSpan(
                        text: '$status · $statusDesc\n',
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(text: '$schema · $schemaDesc'),
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
}
