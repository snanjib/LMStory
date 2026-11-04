import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/core/utils/token_format.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/utils/protocol_display.dart';
import 'package:lmstory/features/settings/presentation/utils/provider_endpoint_preview.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_capability_badges.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_edit_dialog.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_picker_dialog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 供应商详情页
///
/// 对标 ChatBox 的 ProviderSettings：一个页面里同时管理 API Key、API Host、
/// 模型列表。一个供应商 = 一份完整配置单元。
class ProviderDetailPage extends ConsumerStatefulWidget {
  const ProviderDetailPage({required this.presetId, super.key});

  final String presetId;

  @override
  ConsumerState<ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends ConsumerState<ProviderDetailPage> {
  /// 高级参数编辑器是否有未保存文本。脏时禁用采样参数开关，
  /// 避免开关写库后被随后保存的旧文本静默覆盖。
  bool _advancedDirty = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () {
        // 已有数据时静默刷新（不闪全屏 spinner）。
        final hasData = ref.read(settingsNotifierProvider).presets.isNotEmpty;
        return ref
            .read(settingsNotifierProvider.notifier)
            .refresh(silent: hasData);
      },
    );
  }

  ApiPreset? _findPreset(List<ApiPreset> presets) {
    final matches = presets.where((p) => p.presetId == widget.presetId);
    return matches.isEmpty ? null : matches.first;
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    // 仅订阅本页消费的字段切片：其它设置字段的变更不再触发本页重建
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    final isLoading = ref.watch(
      settingsNotifierProvider.select((s) => s.isLoading),
    );
    final apiKeyStatus = ref.watch(
      settingsNotifierProvider.select((s) => s.apiKeyStatus),
    );
    final preset = _findPreset(presets);

    if (isLoading) {
      return Scaffold(
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        appBar: context.lmUi.appBar(context, title: t.settings.provider.title),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (preset == null) {
      return Scaffold(
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        appBar: context.lmUi.appBar(context, title: t.settings.provider.title),
        body: Center(
          child: Text(
            t.common.error,
            style: SimpleTextStyles.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    final hasApiKey = apiKeyStatus[preset.presetId] ?? false;

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: context.lmUi.appBar(
        context,
        title: preset.name,
        actions: [
          // 基于模板创建的 preset（有 templateId）可重置为模板默认值
          if (preset.templateId != null)
            IconButton(
              icon: const Icon(Icons.restart_alt_outlined),
              tooltip: t.settings.provider.reset,
              onPressed: () => _confirmReset(context, preset),
            ),
          // 所有 preset 均可删除
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: t.settings.provider.delete,
            onPressed: () => _confirmDelete(context, preset),
          ),
        ],
      ),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          children: [
            _Section(title: t.settings.provider.name),
            _NameField(preset: preset),
            const SizedBox(height: SimpleSpacing.sXl),
            _Section(title: t.settings.provider.protocol),
            _ProtocolField(preset: preset),
            const SizedBox(height: SimpleSpacing.sXl),
            _Section(title: t.settings.provider.baseUrl),
            _BaseUrlField(preset: preset),
            const SizedBox(height: SimpleSpacing.sXl),
            _Section(title: t.settings.provider.apiKey),
            _ApiKeyField(preset: preset, hasApiKey: hasApiKey),
            const SizedBox(height: SimpleSpacing.sXl),
            _ModelsSection(preset: preset),
            const SizedBox(height: SimpleSpacing.sXl),
            _Section(title: t.settings.provider.samplingParams.title),
            _SamplingOmitSwitch(
              preset: preset,
              editorDirty: _advancedDirty,
            ),
            const SizedBox(height: SimpleSpacing.sXl),
            _Section(title: t.settings.provider.advancedOptions.title),
            _ProviderOptionsField(
              preset: preset,
              onDirtyChanged: (dirty) {
                if (_advancedDirty == dirty) return;
                setState(() => _advancedDirty = dirty);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, ApiPreset preset) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.provider.reset,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.provider.resetConfirm,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.warning),
            child: Text(
              t.settings.provider.reset,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final success = await ref
        .read(settingsNotifierProvider.notifier)
        .resetPreset(preset.presetId);

    if (!mounted) return;
    if (!success) {
      // 重置失败：notifier 已将异常写入 state.error
      if (!context.mounted) return;
      final error = ref.read(settingsNotifierProvider).error ?? t.common.error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            '${t.common.error}: $error',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: colors.error,
        ),
      );
      ref.read(settingsNotifierProvider.notifier).clearError();
      return;
    }
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          t.settings.provider.resetDone,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ApiPreset preset) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.provider.delete,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.provider.deleteConfirm(name: preset.name),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(
              t.common.delete,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final ok = await ref.read(settingsNotifierProvider.notifier).deletePreset(
          preset.presetId,
        );
    if (!context.mounted) return;
    if (!ok) {
      // 删除失败留在本页并提示（同 _confirmReset 口径）——失败也 pop 会把
      // 用户甩回列表，错误只剩日志可寻
      final error = ref.read(settingsNotifierProvider).error ?? t.common.error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(error),
        ),
      );
      return;
    }
    Navigator.of(context).pop();
  }
}

/// 区块标题
class _Section extends StatelessWidget {
  const _Section({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: SimpleSpacing.sSm),
        child: SectionHeading(title: title),
      );
}

/// updatePreset 失败返回 null 且已把异常写入
/// state.error——与 _ProviderOptionsField._save同口径给失败
/// 反馈（floating SnackBar + clearError），调用方留在编辑态不误报已保存。
void _showPresetSaveFailed(
  BuildContext context,
  WidgetRef ref,
  Translations t,
) {
  final colors = context.lm.palette;
  final detail = ref.read(settingsNotifierProvider).error ?? t.common.error;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(
        '${t.common.error}: $detail',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      backgroundColor: colors.error,
    ),
  );
  ref.read(settingsNotifierProvider.notifier).clearError();
}

/// 供应商名称编辑（订正：所有 preset 直接编辑——v0.2 起 DOC-12
/// §4.3 已改为覆盖式更新，无 fork-on-write 行为）
class _NameField extends ConsumerStatefulWidget {
  const _NameField({required this.preset});
  final ApiPreset preset;

  @override
  ConsumerState<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends ConsumerState<_NameField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.preset.name);
  bool _editing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Row(
      children: [
        Expanded(
          child: _editing
              ? TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                )
              : Text(
                  widget.preset.name,
                  style: SimpleTextStyles.body.copyWith(color: colors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(width: SimpleSpacing.sSm),
        if (_editing)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                // 取消时回填持久值——此前残留未保存文本，
                // 再点编辑显示的是上次放弃的内容。
                onPressed: () {
                  _controller.text = widget.preset.name;
                  setState(() => _editing = false);
                },
                child: Text(
                  t.common.cancel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  // 重命名空校验——''非 null 会穿透 copyWith 直接
                  /// 生效，列表出现无名卡片（创建路径有校验，此处没有）
                  final trimmed = _controller.text.trim();
                  if (trimmed.isEmpty) return;
                  final updated = await ref
                      .read(settingsNotifierProvider.notifier)
                      .updatePreset(
                        widget.preset.presetId,
                        name: trimmed,
                      );
                  // 闭包捕获的是 build 参数 context，mounted 守卫须作用其上
                  if (!context.mounted) return;
                  if (updated == null) {
                    // 保存失败留在编辑态并给失败反馈，不静默退出
                    _showPresetSaveFailed(context, ref, t);
                    return;
                  }
                  setState(() => _editing = false);
                },
                child: Text(
                  t.common.save,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          )
        else
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: t.common.edit,
            onPressed: () => setState(() => _editing = true),
          ),
      ],
    );
  }
}

/// 协议类型只读显示（DOC-12 §9.3）
///
/// 所有 preset 的 protocol 均不可修改：
/// - 内置 preset 代表模板协议
/// - 自定义 preset 在创建时选定后锁定
class _ProtocolField extends StatelessWidget {
  const _ProtocolField({required this.preset});
  final ApiPreset preset;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.sXs + 2,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 14, color: colors.faint),
          const SizedBox(width: SimpleSpacing.sXs),
          Expanded(
            child: Text(
              protocolDisplayName(preset.protocol, t),
              style: SimpleTextStyles.body.copyWith(color: colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            t.settings.provider.protocolReadOnly,
            style: SimpleTextStyles.overline.copyWith(color: colors.faint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// API Host 编辑
///
/// 增强体验（对标 ChatBox 的 URL 输入提示）：
/// - 编辑时显示 helperText，说明只需填基础地址，系统自动补全路径
/// - 实时预览解析后的完整请求地址，让用户确认 URL 层级正确
/// - 未设置时显示"未设置"占位，引导用户点击编辑
/// - 手动开关：打开后用户需输入完整 URL，系统不做任何补全
///   用于供应商端点非标准的情况（如 /v4/chat/completion 单数）
///   手动模式通过 baseUrl 字段的 `raw:` 前缀持久化，无需修改数据库 schema
class _BaseUrlField extends ConsumerStatefulWidget {
  const _BaseUrlField({required this.preset});
  final ApiPreset preset;

  @override
  ConsumerState<_BaseUrlField> createState() => _BaseUrlFieldState();
}

class _BaseUrlFieldState extends ConsumerState<_BaseUrlField> {
  late final TextEditingController _controller = TextEditingController(
    text: ApiUrlResolver.displayName(widget.preset.baseUrl),
  );
  bool _editing = false;
  // 手动模式：从持久化的 baseUrl 中读取初始状态
  late bool _useRawUrl = ApiUrlResolver.isRawMode(widget.preset.baseUrl);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 是否为显式明文 http 地址（安全评测 N-1 警示的判定口径）。
  ///
  /// 只认 `http://` 前缀：无 scheme 的输入由 [ApiUrlResolver] 自动补
  /// https，不构成明文；`https://` 天然安全。手动 raw 模式与自动补全
  /// 模式同口径（对用户可见的地址文本判定）。
  static bool _isInsecureHttpUrl(String url) =>
      url.trim().toLowerCase().startsWith('http://');

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _editing
                  ? TextField(
                      controller: _controller,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        hintText: t.settings.provider.baseUrlHint,
                        helperText: _useRawUrl
                            ? t.settings.provider.baseUrlHelperRaw
                            : t.settings.provider.baseUrlHelper,
                        helperMaxLines: 3,
                      ),
                      onChanged: (_) => setState(() {}),
                    )
                  : Text(
                      widget.preset.baseUrl.isEmpty
                          ? t.settings.provider.baseUrlEmpty
                          : ApiUrlResolver.displayName(widget.preset.baseUrl),
                      style: SimpleTextStyles.body.copyWith(
                        color: widget.preset.baseUrl.isEmpty
                            ? colors.faint
                            : colors.muted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            if (_editing)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    // 取消时回填持久值（displayName 剥 raw: 前缀）。
                    onPressed: () {
                      _controller.text =
                          ApiUrlResolver.displayName(widget.preset.baseUrl);
                      setState(() => _editing = false);
                    },
                    child: Text(
                      t.common.cancel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      // 保存时根据手动模式决定是否添加 raw: 前缀
                      final rawBaseUrl = _controller.text.trim();
                      final savedBaseUrl = _useRawUrl && rawBaseUrl.isNotEmpty
                          ? '${ApiUrlResolver.rawPrefix}$rawBaseUrl'
                          : rawBaseUrl;
                      final updated = await ref
                          .read(settingsNotifierProvider.notifier)
                          .updatePreset(
                            widget.preset.presetId,
                            baseUrl: savedBaseUrl,
                          );
                      // 闭包捕获的是 build 参数 context，mounted 守卫须作用其上
                      if (!context.mounted) return;
                      if (updated == null) {
                        // 保存失败留在编辑态并给失败反馈，不静默退出
                        _showPresetSaveFailed(context, ref, t);
                        return;
                      }
                      setState(() => _editing = false);
                    },
                    child: Text(
                      t.common.save,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            else
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: t.common.edit,
                onPressed: () => setState(() => _editing = true),
              ),
          ],
        ),
        // 手动模式开关（仅编辑时显示）
        if (_editing)
          Padding(
            padding: const EdgeInsets.only(top: SimpleSpacing.sXs),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                t.settings.provider.baseUrlRawMode,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                t.settings.provider.baseUrlRawModeHint,
                style: SimpleTextStyles.overline.copyWith(color: colors.faint),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              value: _useRawUrl,
              activeThumbColor: colors.primary,
              onChanged: (v) => setState(() => _useRawUrl = v),
            ),
          ),
        // 预览解析结果（编辑时实时更新，非编辑时显示已保存的解析结果）
        // 让用户直观确认 URL 层级是否正确（避免 /v1/v1 这类重复拼接）
        Builder(
          builder: (context) {
            final previewBaseUrl = _editing
                ? (_useRawUrl
                    ? '${ApiUrlResolver.rawPrefix}${_controller.text.trim()}'
                    : _controller.text.trim())
                : widget.preset.baseUrl;
            if (previewBaseUrl.isEmpty) return const SizedBox.shrink();
            // 预览与真实出网同源——按协议经适配器工厂取 buildUrl，
            // 不再硬编码 /chat/completions（anthropic 实际是 /messages、
            // gemini 是 /v1beta/models/{model}:generateContent）
            final resolvedUrl = buildProviderEndpointPreview(
              protocol: widget.preset.protocol,
              baseUrl: previewBaseUrl,
            );
            return Padding(
              padding: const EdgeInsets.only(top: SimpleSpacing.sXs),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sSm,
                  vertical: SimpleSpacing.sXs,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
                child: Text(
                  t.settings.provider.baseUrlPreview(url: resolvedUrl),
                  style:
                      SimpleTextStyles.overline.copyWith(color: colors.faint),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          },
        ),
        // 明文 http 警示（安全评测 N-1）：编辑态看输入框实时值，非编辑态
        // 看已保存地址。仅显式 http:// 前缀触发（无 scheme 输入会被解析器
        // 自动补 https，不算明文）；Dart 网络栈不受系统 cleartext 门控，
        // 这是明文传输的唯一提示层。
        Builder(
          builder: (context) {
            final effectiveUrl = _editing
                ? _controller.text.trim()
                : ApiUrlResolver.displayName(widget.preset.baseUrl);
            if (!_isInsecureHttpUrl(effectiveUrl)) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: SimpleSpacing.sXs),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sSm,
                  vertical: SimpleSpacing.sXs,
                ),
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                  border: Border.all(color: colors.warning),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      size: 14,
                      color: colors.warning,
                    ),
                    const SizedBox(width: SimpleSpacing.sXs),
                    Expanded(
                      child: Text(
                        t.settings.provider.insecureHostWarning,
                        style: SimpleTextStyles.overline
                            .copyWith(color: colors.warning),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// API Key 编辑（密文显示，点击切换可见）
class _ApiKeyField extends ConsumerStatefulWidget {
  const _ApiKeyField({required this.preset, required this.hasApiKey});
  final ApiPreset preset;
  final bool hasApiKey;

  @override
  ConsumerState<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends ConsumerState<_ApiKeyField> {
  final _controller = TextEditingController();
  bool _obscured = true;
  bool _editing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_editing)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  obscureText: _obscured,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: t.settings.provider.apiKeyHint,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 20,
                      ),
                      // 切换态即动作结果：显示中→动作是「隐藏」，反之亦然。
                      tooltip: _obscured
                          ? t.common.showPassword
                          : t.common.hidePassword,
                      onPressed: () => setState(() => _obscured = !_obscured),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              TextButton(
                onPressed: () => setState(() {
                  _editing = false;
                  _controller.clear();
                }),
                child: Text(
                  t.common.cancel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  // 编辑态空保存=清除 Key（G3 后是
                  // 一键无声破坏性操作）——原 Key 已设置时先确认
                  final trimmed = _controller.text.trim();
                  final hasExistingKey = ref
                          .read(settingsNotifierProvider)
                          .apiKeyStatus[widget.preset.presetId] ??
                      false;
                  if (trimmed.isEmpty && hasExistingKey) {
                    final confirmed = await showLmDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(
                          t.settings.provider.clearKeyConfirmTitle,
                        ),
                        content: Text(
                          t.settings.provider.clearKeyConfirmBody,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(t.common.cancel),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(t.common.confirm),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;
                  }
                  final saved = await ref
                      .read(settingsNotifierProvider.notifier)
                      .saveApiKey(
                        widget.preset.presetId,
                        trimmed,
                      );
                  if (!context.mounted) return;
                  if (!saved) {
                    // 存储失败留在编辑态并提示——静默失败会让用户以为已保存
                    final error = ref.read(settingsNotifierProvider).error ??
                        t.common.error;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(error),
                      ),
                    );
                    return;
                  }
                  setState(() {
                    _editing = false;
                    _controller.clear();
                  });
                },
                child: Text(
                  t.common.save,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              Icon(
                Icons.circle,
                size: 8,
                color: widget.hasApiKey ? colors.success : colors.warning,
              ),
              const SizedBox(width: SimpleSpacing.sXs),
              Expanded(
                child: Text(
                  widget.hasApiKey
                      ? t.settings.provider.apiKeyStatus.set
                      : t.settings.provider.apiKeyStatus.notSet,
                  style: SimpleTextStyles.body.copyWith(color: colors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _editing = true;
                  _obscured = true;
                }),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(
                  t.common.edit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SimpleSpacing.sXs),
              Tooltip(
                message: t.settings.provider.testHint,
                child: Consumer(
                  builder: (context, ref, _) {
                    // 进行中禁用+spinner，防连点（对照拉模型按钮口径）
                    final testing = ref.watch(
                      settingsNotifierProvider.select(
                        (s) => s.isTestingConnection,
                      ),
                    );
                    return TextButton.icon(
                      onPressed:
                          testing ? null : () => _testConnection(context),
                      icon: testing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering_outlined, size: 18),
                      label: Text(
                        t.settings.provider.test,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _testConnection(BuildContext context) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(settingsNotifierProvider.notifier);
    await notifier.testConnection(widget.preset.presetId);
    if (!mounted) return;

    final result = ref.read(settingsNotifierProvider).testResult;
    final String message;
    final bool isOk;
    if (result == 'success') {
      message = t.settings.provider.testResult.success;
      isOk = true;
    } else {
      // 控制器按状态码分类（auth/network/endpoint/
      // server/unknown），UI 映射人话提示；原始异常附在第二行便于排查
      final parts = (result ?? 'fail:unknown|').replaceFirst('fail:', '');
      final bar = parts.indexOf('|');
      final kind = bar == -1 ? 'unknown' : parts.substring(0, bar);
      final raw = bar == -1 ? parts : parts.substring(bar + 1);
      final labels = t.settings.provider.testResult;
      final headline = switch (kind) {
        'auth' => labels.failAuth(status: '401/403'),
        'network' => labels.failNetwork,
        'endpoint' => labels.failEndpoint(status: '404'),
        'server' => labels.failServer(status: '5xx'),
        _ => labels.fail(error: raw),
      };
      message = kind == 'unknown' ? headline : '$headline\n$raw';
      isOk = false;
    }

    scaffoldMessenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          message,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: isOk ? colors.success : colors.error,
      ),
    );
    notifier.clearTestResult();
  }
}

/// 供应商级「不发送采样参数」开关
///
/// 写入 [kOmitSamplingParamsOption] 保留键，由三个协议适配器统一消费。
/// 高级参数编辑器有未保存文本时禁用，避免开关写库被随后保存的旧文本覆盖。
class _SamplingOmitSwitch extends ConsumerStatefulWidget {
  const _SamplingOmitSwitch({
    required this.preset,
    required this.editorDirty,
  });

  final ApiPreset preset;
  final bool editorDirty;

  @override
  ConsumerState<_SamplingOmitSwitch> createState() =>
      _SamplingOmitSwitchState();
}

class _SamplingOmitSwitchState extends ConsumerState<_SamplingOmitSwitch> {
  bool _saving = false;

  bool get _omit =>
      widget.preset.providerOptions?[kOmitSamplingParamsOption] == true;

  Future<void> _toggle(bool omit) async {
    setState(() => _saving = true);
    final updated = await ref
        .read(settingsNotifierProvider.notifier)
        .setOmitSamplingParams(widget.preset.presetId, omit: omit);
    if (!mounted) return;
    setState(() => _saving = false);
    if (updated == null) {
      _showPresetSaveFailed(context, ref, Translations.of(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final enabled = !_saving && !widget.editorDirty;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        t.settings.provider.samplingParams.omitTitle,
        style: SimpleTextStyles.caption.copyWith(color: colors.muted),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        widget.editorDirty
            ? t.settings.provider.samplingParams.editorDirtyHint
            : t.settings.provider.samplingParams.omitSubtitle,
        style: SimpleTextStyles.overline.copyWith(color: colors.faint),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      value: _omit,
      activeThumbColor: colors.primary,
      onChanged: enabled ? _toggle : null,
    );
  }
}

/// 高级参数（providerOptions）折叠编辑区
///
/// 多行 JSON 文本域绑定 [ApiPreset.providerOptions]：非空时校验为
/// JSON 对象（Map<String, dynamic>），错误行内提示不阻断其他字段；
/// 空串保存 = 清除该字段（空就是空，不做隐义）。校验通过才启用保存。
class _ProviderOptionsField extends ConsumerStatefulWidget {
  const _ProviderOptionsField({
    required this.preset,
    this.onDirtyChanged,
  });
  final ApiPreset preset;

  /// 未保存文本状态变化时回调；仅在脏/净状态翻转时触发。
  final ValueChanged<bool>? onDirtyChanged;

  @override
  ConsumerState<_ProviderOptionsField> createState() =>
      _ProviderOptionsFieldState();
}

class _ProviderOptionsFieldState extends ConsumerState<_ProviderOptionsField> {
  static const JsonEncoder _prettyEncoder = JsonEncoder.withIndent('  ');

  bool _expanded = false;
  late String _initialText = _textOf(widget.preset);
  late final TextEditingController _controller =
      TextEditingController(text: _initialText);

  static String _textOf(ApiPreset preset) {
    final options = preset.providerOptions;
    if (options == null || options.isEmpty) return '';
    return _prettyEncoder.convert(options);
  }

  /// 三协议对 providerOptions 的消费面差异大
  /// （Gemini 无 extra_headers/extra_body 通道、Anthropic 无
  /// extra_body），helperText 按协议列有效键位，避免跨协议照抄
  /// 示例键后静默无效。
  String _protocolHint(LlmProtocol protocol, Translations t) =>
      switch (protocol) {
        LlmProtocol.anthropic =>
          t.settings.provider.advancedOptions.hintAnthropic,
        LlmProtocol.geminiNative =>
          t.settings.provider.advancedOptions.hintGemini,
        // openaiCompatible / openaiResponses 共用 OpenAI 适配器消费面
        _ => t.settings.provider.advancedOptions.hintOpenai,
      };

  /// 文本 → 参数 Map。空串返回 null（清除）；非法 JSON 或非对象返回错误文案键。
  static (Map<String, dynamic>?, String?) _parse(
    String text,
    Translations t,
  ) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return (null, null);
    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return (null, t.settings.provider.advancedOptions.invalidJson);
    }
    if (decoded is! Map<String, dynamic>) {
      return (null, t.settings.provider.advancedOptions.mustBeObject);
    }
    return (decoded, null);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _notifyDirty() {
    widget.onDirtyChanged?.call(
      _controller.text.trim() != _initialText.trim(),
    );
  }

  @override
  void didUpdateWidget(covariant _ProviderOptionsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部变更（AppBar「重置为模板默认值」等入口
    // 改写 providerOptions）同步进展开中的编辑器——仅当本地无未保存
    // 改动（非脏）时回填持久值，避免覆盖用户正在编辑的内容。
    final newText = _textOf(widget.preset);
    if (newText != _textOf(oldWidget.preset) &&
        _controller.text.trim() == _initialText.trim()) {
      _initialText = newText;
      _controller.text = newText;
    }
  }

  Future<void> _save(Translations t) async {
    final (options, error) = _parse(_controller.text, t);
    if (error != null) return;
    final updated =
        await ref.read(settingsNotifierProvider.notifier).updatePreset(
              widget.preset.presetId,
              providerOptions: options,
            );
    if (!mounted) return;
    if (updated == null) {
      // updatePreset 失败返回 null 且已把异常写入
      // state.error——与 _confirmReset 同口径给失败反馈，不再误报已保存
      final colors = context.lm.palette;
      final detail = ref.read(settingsNotifierProvider).error ?? t.common.error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            '${t.common.error}: $detail',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: colors.error,
        ),
      );
      ref.read(settingsNotifierProvider.notifier).clearError();
      return;
    }
    // 回填以刚持久化的实体为准——此刻 widget.preset
    // 仍是重建前的旧对象，读它会把「保存前文本」当作新基线，清除后
    // 重新展开会复活已删内容
    setState(() {
      _initialText = _textOf(updated);
      _controller.text = _initialText;
      _expanded = false;
    });
    _notifyDirty();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          t.settings.provider.advancedOptions.saved,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final options = widget.preset.providerOptions;
    final configuredCount =
        options == null || options.isEmpty ? 0 : options.length;

    if (!_expanded) {
      return InkWell(
        onTap: () => setState(() => _expanded = true),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sSm,
            vertical: SimpleSpacing.sXs + 2,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  configuredCount > 0
                      ? t.settings.provider.advancedOptions
                          .summaryConfigured(count: configuredCount)
                      : t.settings.provider.advancedOptions.summaryEmpty,
                  style: SimpleTextStyles.body.copyWith(
                    color: configuredCount > 0 ? colors.muted : colors.faint,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.expand_more, size: 18, color: colors.faint),
            ],
          ),
        ),
      );
    }

    // 实时校验：错误行内直显，随输入更新；空串合法（= 清除）
    final (_, parseError) = _parse(_controller.text, t);
    final isDirty = _controller.text.trim() != _initialText.trim();
    final canSave = parseError == null && isDirty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          keyboardType: TextInputType.multiline,
          maxLines: 6,
          minLines: 4,
          style: SimpleTextStyles.body.copyWith(color: colors.ink),
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            // 占位示例改中性 extra_headers——原示例
            // `{"thinking": {"type": "enabled"}}` 两次被探索者误读为「已
            // 配置现值」（定界），且照抄该值在 Agnes 等
            // OpenAI 兼容端点上实测触发 TLS 重置（厂商方言需端点支持）。
            hintText: '{"extra_headers": {"X-Custom-Key": "value"}}',
            errorText: parseError,
            helperText: _protocolHint(widget.preset.protocol, t),
            helperMaxLines: 6,
          ),
          onChanged: (_) {
            setState(() {});
            _notifyDirty();
          },
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () {
                _controller.text = _initialText;
                setState(() => _expanded = false);
                _notifyDirty();
              },
              child: Text(
                t.common.cancel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            ElevatedButton(
              // 校验通过且有改动才可保存（空串 = 清除，同样允许）
              onPressed: canSave ? () => _save(t) : null,
              child: Text(
                t.common.save,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 拉模型字段级保手工——同 modelId 已存在的行，
/// existing 非空非默认的字段（displayName/capabilities/contextWindow/
/// maxOutput/type）保留用户手工/实测标注，其余随拉取行更新。
/// 顶层纯函数与页面接线分离，便于行为测试（照 lruEvictCandidates 先例）。
ModelInfo mergePreservingManualFields(ModelInfo? existing, ModelInfo fetched) {
  if (existing == null) return fetched;
  return ModelInfo(
    modelId: fetched.modelId,
    displayName: (existing.displayName ?? '').isNotEmpty
        ? existing.displayName
        : fetched.displayName,
    // 拉取解析侧不产出 type（恒默认 chat），无条件保留即恒保手工
    type: existing.type,
    capabilities: existing.capabilities.isNotEmpty
        ? existing.capabilities
        : fetched.capabilities,
    contextWindow: existing.contextWindow != null && existing.contextWindow! > 0
        ? existing.contextWindow
        : fetched.contextWindow,
    maxOutput: existing.maxOutput != null && existing.maxOutput! > 0
        ? existing.maxOutput
        : fetched.maxOutput,
    labels: fetched.labels,
  );
}

/// 模型列表区块（拉取/添加/删除/批量删除）
class _ModelsSection extends ConsumerStatefulWidget {
  const _ModelsSection({required this.preset});
  final ApiPreset preset;

  @override
  ConsumerState<_ModelsSection> createState() => _ModelsSectionState();
}

class _ModelsSectionState extends ConsumerState<_ModelsSection> {
  /// 多选模式开关
  bool _selectionMode = false;

  /// 多选模式下被选中的 modelId 集合
  final Set<String> _selectedIds = <String>{};

  /// 进入/退出多选模式
  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      _selectedIds.clear();
    });
  }

  /// 切换单个模型的选中状态
  void _toggleSelect(String modelId) {
    setState(() {
      if (_selectedIds.contains(modelId)) {
        _selectedIds.remove(modelId);
      } else {
        _selectedIds.add(modelId);
      }
    });
  }

  /// 全选 / 取消全选
  void _toggleSelectAll(List<ModelInfo> models) {
    setState(() {
      if (_selectedIds.length == models.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(models.map((m) => m.modelId));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    // 仅订阅 presets 切片：其它设置字段变更不触发本组件重建
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    final isFetchingModels = ref.watch(
      settingsNotifierProvider.select((s) => s.isFetchingModels),
    );
    // 重新读取最新的 preset（模型列表可能已更新）
    final preset = presets.firstWhere(
      (p) => p.presetId == widget.preset.presetId,
      orElse: () => widget.preset,
    );
    final models = preset.cachedModels;
    final allSelected =
        models.isNotEmpty && _selectedIds.length == models.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PanelHeading(
          title: t.settings.provider.models,
          subtitle: '(${models.length})',
          actions: [
            // 多选模式开关（仅在有模型时可用）
            if (models.isNotEmpty)
              _IconAction(
                icon: Icon(
                  _selectionMode ? Icons.close : Icons.checklist_outlined,
                  size: 18,
                ),
                label: _selectionMode
                    ? t.common.cancel
                    : t.settings.provider.batchSelect,
                onPressed: _toggleSelectionMode,
              ),
            if (models.isNotEmpty) const SizedBox(width: SimpleSpacing.sXs),
            // 获取模型列表
            _IconAction(
              icon: isFetchingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: t.settings.provider.fetchModels,
              onPressed: isFetchingModels ? null : () => _fetchModels(context),
            ),
            const SizedBox(width: SimpleSpacing.sXs),
            _IconAction(
              icon: const Icon(Icons.add, size: 18),
              label: t.settings.provider.addModel,
              onPressed: () => _showAddModelDialog(context),
            ),
          ],
        ),
        // 多选模式下的操作栏
        if (_selectionMode) ...[
          const SizedBox(height: SimpleSpacing.sSm),
          _BatchActionBar(
            selectedCount: _selectedIds.length,
            totalCount: models.length,
            allSelected: allSelected,
            onToggleSelectAll: () => _toggleSelectAll(models),
            onDelete: () => _confirmBatchDelete(context, models),
          ),
        ],
        const SizedBox(height: SimpleSpacing.sSm),
        if (models.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sLg),
            child: Center(
              child: Text(
                t.settings.provider.noModels,
                style: SimpleTextStyles.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: models.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                thickness: 1,
                color: colors.divider,
              ),
              itemBuilder: (context, index) {
                final model = models[index];
                final selected = _selectedIds.contains(model.modelId);
                return _ModelItem(
                  model: model,
                  selectionMode: _selectionMode,
                  selected: selected,
                  onTap: _selectionMode
                      ? () => _toggleSelect(model.modelId)
                      : null,
                  onEdit:
                      _selectionMode ? null : () => _editModel(context, model),
                  onDelete: _selectionMode
                      ? null
                      : () => _deleteModel(context, model),
                );
              },
            ),
          ),
      ],
    );
  }

  /// 批量删除确认 + 执行
  Future<void> _confirmBatchDelete(
    BuildContext context,
    List<ModelInfo> models,
  ) async {
    if (_selectedIds.isEmpty) return;
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.provider.batchDelete(count: _selectedIds.length),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.provider.batchDeleteConfirm(count: _selectedIds.length),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(
              t.common.delete,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final newModels =
        models.where((m) => !_selectedIds.contains(m.modelId)).toList();
    await ref.read(settingsNotifierProvider.notifier).updatePresetModels(
          widget.preset.presetId,
          newModels,
        );
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
  }

  Future<void> _fetchModels(BuildContext context) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(settingsNotifierProvider.notifier);
    final fetched = await notifier.fetchModels(widget.preset.presetId);
    if (!mounted) return;

    final error = ref.read(settingsNotifierProvider).fetchModelsError;
    if (error != null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.settings.provider.fetchError(error: error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: colors.error,
        ),
      );
      return;
    }

    // 空结果不再是死寂——部分网关/协议异常会返回 200+空列表，
    // 与"测试连接成功"并存时用户无从理解（修复前的 Gemini 正是此形态）
    if (fetched.isEmpty) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.settings.provider.fetchEmpty),
        ),
      );
      return;
    }
    if (!context.mounted) return;

    // 弹出模型选择弹窗，让用户勾选要加入的模型（对标 ChatBox ModelList）
    final currentPreset = ref.read(settingsNotifierProvider).presets.firstWhere(
          (p) => p.presetId == widget.preset.presetId,
          orElse: () => widget.preset,
        );
    final existingIds =
        currentPreset.cachedModels.map((m) => m.modelId).toSet();

    final selected = await showLmDialog<List<ModelInfo>>(
      context: context,
      builder: (_) => ModelPickerDialog(
        fetchedModels: fetched,
        existingModelIds: existingIds,
      ),
    );

    if (selected == null || !mounted) return;

    // 合并：用户在弹窗里勾选的 + 原有但不在拉取列表里的（手动添加的保留）
    final preserved = currentPreset.cachedModels
        .where((m) => !fetched.any((f) => f.modelId == m.modelId))
        .toList();
    // 字段级保手工——同 modelId 已存在的行，用户
    // 改过的字段（非空非默认）不被拉取的富化行整行覆盖，只增不改。
    final existingById = {
      for (final m in currentPreset.cachedModels) m.modelId: m,
    };
    final newModels = [
      ...preserved,
      for (final f in selected)
        mergePreservingManualFields(existingById[f.modelId], f),
    ];

    await ref.read(settingsNotifierProvider.notifier).updatePresetModels(
          widget.preset.presetId,
          newModels,
        );
  }

  Future<void> _showAddModelDialog(BuildContext context) async {
    final t = Translations.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final result = await showLmDialog<ModelInfo>(
      context: context,
      builder: (_) => ModelEditDialog(presetId: widget.preset.presetId),
    );

    if (result == null || !mounted) return;

    final state = ref.read(settingsNotifierProvider);
    final preset = state.presets.firstWhere(
      (p) => p.presetId == widget.preset.presetId,
      orElse: () => widget.preset,
    );
    // 避免重复添加同 modelId
    if (preset.cachedModels.any((m) => m.modelId == result.modelId)) {
      // 此前复用输入框占位文案「输入模型 ID」当"已存在"警告用
      scaffoldMessenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.settings.provider.modelIdDuplicate(modelId: result.modelId),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
      return;
    }
    final newModels = [...preset.cachedModels, result];
    await ref.read(settingsNotifierProvider.notifier).updatePresetModels(
          widget.preset.presetId,
          newModels,
        );
  }

  Future<void> _editModel(BuildContext context, ModelInfo model) async {
    final result = await showLmDialog<ModelInfo>(
      context: context,
      builder: (_) => ModelEditDialog(
        presetId: widget.preset.presetId,
        existingModel: model,
      ),
    );

    if (result == null || !mounted) return;

    final state = ref.read(settingsNotifierProvider);
    final preset = state.presets.firstWhere(
      (p) => p.presetId == widget.preset.presetId,
      orElse: () => widget.preset,
    );
    final newModels = preset.cachedModels
        .map((m) => m.modelId == model.modelId ? result : m)
        .toList();
    await ref.read(settingsNotifierProvider.notifier).updatePresetModels(
          widget.preset.presetId,
          newModels,
        );
  }

  Future<void> _deleteModel(BuildContext context, ModelInfo model) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.provider.deleteModel,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.provider.deleteModelConfirm(
            name: model.displayName ?? model.modelId,
          ),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(
              t.common.delete,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final state = ref.read(settingsNotifierProvider);
    final preset = state.presets.firstWhere(
      (p) => p.presetId == widget.preset.presetId,
      orElse: () => widget.preset,
    );
    final newModels =
        preset.cachedModels.where((m) => m.modelId != model.modelId).toList();
    await ref.read(settingsNotifierProvider.notifier).updatePresetModels(
          widget.preset.presetId,
          newModels,
        );
  }
}

class _ModelItem extends StatelessWidget {
  const _ModelItem({
    required this.model,
    required this.onEdit,
    required this.onDelete,
    this.selectionMode = false,
    this.selected = false,
    this.onTap,
  });
  final ModelInfo model;
  // 多选模式下为 null（按钮隐藏），故声明为可空
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return InkWell(
      onTap: onTap,
      // 多选模式下用主色高亮选中行（避免用侧边色条）
      highlightColor:
          selectionMode ? colors.primary.withValues(alpha: 0.06) : null,
      child: Container(
        // 选中行整体用极淡主色背景做反馈，比左侧色条更克制
        color: selectionMode && selected
            ? colors.primary.withValues(alpha: 0.05)
            : null,
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sMd,
          vertical: SimpleSpacing.sSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：图标 + 模型名 + 能力 badges
            Row(
              children: [
                // 多选模式：左侧 checkbox；普通模式：智能体图标
                if (selectionMode) ...[
                  Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 20,
                    color: selected ? colors.primary : colors.faint,
                  ),
                  const SizedBox(width: SimpleSpacing.sSm),
                ] else ...[
                  Icon(
                    Icons.smart_toy_outlined,
                    size: 18,
                    color: colors.faint,
                  ),
                  const SizedBox(width: SimpleSpacing.sSm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.displayName ?? model.modelId,
                        style: SimpleTextStyles.body
                            .copyWith(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (model.capabilities.isNotEmpty) ...[
                        const SizedBox(height: SimpleSpacing.sXs),
                        ModelCapabilityBadges(
                          capabilities: model.capabilities,
                          size: 13,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            // 第二行：上下文 chip + 输出 chip + 编辑/删除按钮
            // 仅在"有元数据 chip"或"非多选模式（需显示编辑/删除按钮）"时显示
            if (!selectionMode ||
                model.contextWindow != null ||
                model.maxOutput != null) ...[
              const SizedBox(height: SimpleSpacing.sXs),
              Wrap(
                spacing: SimpleSpacing.sSm,
                runSpacing: SimpleSpacing.sXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (model.contextWindow != null)
                    _metaChip(
                      context,
                      colors,
                      Icons.straighten,
                      formatTokenCount(model.contextWindow!),
                    ),
                  if (model.maxOutput != null) ...[
                    _metaChip(
                      context,
                      colors,
                      Icons.output,
                      formatTokenCount(model.maxOutput!),
                    ),
                  ],
                  // 多选模式下隐藏行内编辑/删除按钮（避免误操作）
                  if (!selectionMode) ...[
                    IconButton(
                      icon: Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: colors.faint,
                      ),
                      onPressed: onEdit,
                      tooltip: t.common.edit,
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: colors.faint,
                      ),
                      onPressed: onDelete,
                      tooltip:
                          MaterialLocalizations.of(context).deleteButtonTooltip,
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metaChip(
    BuildContext context,
    LmPalette colors,
    IconData icon,
    String text,
  ) =>
      Container(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.s2xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: colors.faint),
            const SizedBox(width: 2),
            Text(
              text,
              style: SimpleTextStyles.overline.copyWith(color: colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
}

/// 多选模式下的操作栏（全选 / 删除 N 项）
class _BatchActionBar extends StatelessWidget {
  const _BatchActionBar({
    required this.selectedCount,
    required this.totalCount,
    required this.allSelected,
    required this.onToggleSelectAll,
    required this.onDelete,
  });

  final int selectedCount;
  final int totalCount;
  final bool allSelected;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final canDelete = selectedCount > 0;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sMd,
        vertical: SimpleSpacing.sSm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          // 已选 N 项
          Expanded(
            child: Text(
              t.settings.provider.batchSelected(count: selectedCount),
              style: SimpleTextStyles.caption.copyWith(color: colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 全选 / 取消全选
          TextButton(
            onPressed: onToggleSelectAll,
            child: Text(
              allSelected
                  ? t.settings.provider.batchDeselectAll
                  : t.settings.provider.batchSelectAll,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sXs),
          // 删除选中
          TextButton(
            onPressed: canDelete ? onDelete : null,
            style: TextButton.styleFrom(
              foregroundColor: canDelete ? colors.error : colors.faint,
            ),
            child: Text(
              t.settings.provider.batchDelete(count: selectedCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final enabled = onPressed != null;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sSm,
          vertical: SimpleSpacing.s2xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DefaultTextStyle.merge(
              style: TextStyle(color: enabled ? colors.muted : colors.faint),
              child: icon,
            ),
            const SizedBox(width: SimpleSpacing.s2xs),
            Text(
              label,
              style: SimpleTextStyles.overline.copyWith(
                color: enabled ? colors.muted : colors.faint,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
