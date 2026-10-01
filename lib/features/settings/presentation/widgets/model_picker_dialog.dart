import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_capability_badges.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模型选择弹窗
///
/// 对标 ChatBox 的 ModelList 弹窗。拉取 /models 后弹出，让用户勾选要加入
/// 供应商配置的模型，避免 OpenRouter 等数百个模型一股脑全加进去。
///
/// 交互：搜索过滤 + 复选勾选 + 能力图标展示。点"保存"返回勾选的模型列表。
class ModelPickerDialog extends StatefulWidget {
  const ModelPickerDialog({
    required this.fetchedModels,
    required this.existingModelIds,
    super.key,
  });

  /// 拉取到的全部模型
  final List<ModelInfo> fetchedModels;

  /// 已在供应商配置中的模型 ID（默认勾选）
  final Set<String> existingModelIds;

  @override
  State<ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<ModelPickerDialog> {
  late final Set<String> _selectedIds;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // 默认勾选已存在的模型 + 拉取到的模型中匹配的
    _selectedIds = {...widget.existingModelIds};
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ModelInfo> get _filtered {
    if (_query.isEmpty) return widget.fetchedModels;
    final q = _query.toLowerCase();
    return widget.fetchedModels.where((m) {
      final name = (m.displayName ?? m.modelId).toLowerCase();
      return name.contains(q) || m.modelId.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Dialog(
      insetPadding: const EdgeInsets.all(SimpleSpacing.sLg),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 600),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(t, colors),
            _searchField(colors),
            const Divider(height: 1),
            Flexible(child: _list(colors)),
            _footer(t, colors),
          ],
        ),
      ),
    );
  }

  Widget _header(Translations t, LmPalette colors) => Padding(
        padding: const EdgeInsets.fromLTRB(
          SimpleSpacing.sLg,
          SimpleSpacing.sLg,
          SimpleSpacing.sMd,
          SimpleSpacing.sSm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      t.settings.provider.models,
                      style: SimpleTextStyles.title2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Text(
                    '(${_selectedIds.length}/${widget.fetchedModels.length})',
                    style:
                        SimpleTextStyles.caption.copyWith(color: colors.muted),
                  ),
                ],
              ),
            ),
            IconButton(
              //  语义缺口：复用 common.close（不新增 i18n key）。
              tooltip: t.common.close,
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );

  Widget _searchField(LmPalette colors) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: SimpleSpacing.sLg),
        child: TextField(
          controller: _searchController,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: t.settings.provider.searchModels,
            hintStyle: SimpleTextStyles.body.copyWith(color: colors.faint),
            prefixIcon: Icon(Icons.search, size: 20, color: colors.faint),
            isDense: true,
            filled: true,
            fillColor: colors.surfaceVariant,
            //  修复：圆角 rMd/rFull→rXs（4px 微圆角），对齐用户偏好"直角边缘"
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sMd,
              vertical: SimpleSpacing.sSm,
            ),
          ),
        ),
      );

  Widget _list(LmPalette colors) {
    final models = _filtered;
    if (models.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SimpleSpacing.s2xl),
          child: Text(
            t.common.noResults,
            style: SimpleTextStyles.body.copyWith(color: colors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: models.length,
      itemBuilder: (context, index) {
        final model = models[index];
        final selected = _selectedIds.contains(model.modelId);
        return _ModelPickItem(
          model: model,
          selected: selected,
          onToggle: () => setState(() {
            if (selected) {
              _selectedIds.remove(model.modelId);
            } else {
              _selectedIds.add(model.modelId);
            }
          }),
        );
      },
    );
  }

  Widget _footer(Translations t, LmPalette colors) => Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.divider)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.sSm,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                t.common.cancel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            ElevatedButton(
              onPressed: () {
                final selected = widget.fetchedModels
                    .where((m) => _selectedIds.contains(m.modelId))
                    .toList();
                Navigator.of(context).pop(selected);
              },
              child: Text(
                t.common.save,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

class _ModelPickItem extends StatelessWidget {
  const _ModelPickItem({
    required this.model,
    required this.selected,
    required this.onToggle,
  });
  final ModelInfo model;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.sSm,
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? colors.primary : colors.faint,
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.displayName ?? model.modelId,
                          style: SimpleTextStyles.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (model.capabilities.isNotEmpty) ...[
                        const SizedBox(width: SimpleSpacing.sXs),
                        ModelCapabilityBadges(
                          capabilities: model.capabilities,
                          size: 13,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.modelId,
                          style: SimpleTextStyles.overline
                              .copyWith(color: colors.muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (model.contextWindow != null) ...[
                        const SizedBox(width: SimpleSpacing.sSm),
                        _metaChip(
                          colors,
                          Icons.straighten,
                          _formatTokens(model.contextWindow!),
                        ),
                      ],
                      if (model.maxOutput != null) ...[
                        const SizedBox(width: SimpleSpacing.sXs),
                        _metaChip(
                          colors,
                          Icons.output,
                          _formatTokens(model.maxOutput!),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(LmPalette colors, IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: colors.faint),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              text,
              style: SimpleTextStyles.overline.copyWith(color: colors.faint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );

  String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).round()}K';
    return '$n';
  }
}
