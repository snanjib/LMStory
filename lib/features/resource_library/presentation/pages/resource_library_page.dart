import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_app_bar.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/utils/file_reader.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_reader_web.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/target_summary.dart';
import 'package:lmstory/features/resource_ai/presentation/pages/resource_ai_page.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/presentation/widgets/resource_content_viewer.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 资源库管理页（角色卡/世界书，DOC-15 §9.1）
///
/// 导入（角色卡 PNG / 世界书 JSON）、列表展示、删除。
class ResourceLibraryPage extends ConsumerStatefulWidget {
  const ResourceLibraryPage({super.key});

  @override
  ConsumerState<ResourceLibraryPage> createState() =>
      _ResourceLibraryPageState();
}

class _ResourceLibraryPageState extends ConsumerState<ResourceLibraryPage> {
  List<CharacterCard> _cards = const [];
  List<Worldbook> _books = const [];
  bool _loading = true;

  /// 列表加载失败信息（非 null = 错误态，展示重试）
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final repo = ref.read(resourceLibraryRepositoryProvider);
      final cards = await repo.getAllCharacterCards();
      final books = await repo.getAllWorldbooks();
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _books = books;
        _loading = false;
        _errorMessage = null;
      });
    } catch (e) {
      // 此前无守卫，仓储抛 QueryException 时异常逃逸且
      // _loading 停留在 true → 无限转圈、无重试入口。对齐同文件
      // 删除入口的 catch 口径与 factual_memory_tab 的三态范式。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '$e';
      });
    }
  }

  Future<void> _importCard() async {
    final t = Translations.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;

      final Uint8List bytes;
      if (kIsWeb) {
        if (picked.bytes == null) return;
        bytes = picked.bytes!;
      } else {
        final path = picked.path;
        if (path == null) return;
        bytes = await readFileBytesNative(path);
      }

      final imported = await ref
          .read(resourceImportServiceProvider)
          .importCardBytes(bytes, fallbackName: picked.name);
      if (!mounted) return;
      _showSnack(t.settings.resourceLibrary.imported(name: imported.name));
      await _reload();
    } catch (e) {
      if (mounted) {
        _showSnack(t.settings.resourceLibrary.importFailed(error: '$e'));
      }
    }
  }

  /// F9 修复：纯 JSON 角色卡（V2/V3）应用内导入
  Future<void> _importCardJson() async {
    final t = Translations.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;

      final String content;
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null) return;
        content = utf8.decode(bytes, allowMalformed: true);
      } else {
        final path = picked.path;
        if (path == null) return;
        // 宽容解码与 web/分享路径统一口径
        content = await readFileTextLenientNative(path);
      }

      final imported = await ref
          .read(resourceImportServiceProvider)
          .importCardJson(content, fallbackName: picked.name);
      if (!mounted) return;
      _showSnack(t.settings.resourceLibrary.imported(name: imported.name));
      await _reload();
    } catch (e) {
      if (mounted) {
        _showSnack(t.settings.resourceLibrary.importFailed(error: '$e'));
      }
    }
  }

  Future<void> _importBook() async {
    final t = Translations.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;

      final String content;
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null) return;
        //  修复：按 UTF-8 解码。此前 String.fromCharCodes
        // 把 UTF-8 字节当码点，中文世界书内容在 Web 端必然乱码入库。
        content = utf8.decode(bytes, allowMalformed: true);
      } else {
        final path = picked.path;
        if (path == null) return;
        // 宽容解码与 web/分享路径统一口径
        content = await readFileTextLenientNative(path);
      }

      final imported = await ref
          .read(resourceImportServiceProvider)
          .importWorldbookContent(content, fallbackName: picked.name);
      if (!mounted) return;
      _showSnack(t.settings.resourceLibrary.imported(name: imported.name));
      await _reload();
    } catch (e) {
      if (mounted) {
        _showSnack(t.settings.resourceLibrary.importFailed(error: '$e'));
      }
    }
  }

  Future<void> _deleteCard(CharacterCard card) async {
    final t = Translations.of(context);
    final confirmed = await _confirmDelete(
      t.settings.resourceLibrary.deleteConfirm(name: card.name),
    );
    if (confirmed != true) return;
    try {
      await ref.read(resourceLibraryRepositoryProvider).deleteCharacterCard(
            card.cardId,
          );
    } catch (e) {
      // 删除含跨会话级联，仓储失败包成
      // QueryException 上抛——此前无兜底直接逃逸到框架层，用户无感知。
      if (mounted) {
        _showSnackFloating(
          '${t.intermediate.memoryBrowser.deleteFailed}: $e',
        );
      }
      return;
    }
    // 删除成功补明确反馈——此前仅靠 tile 消失
    // 暗示成功，叠加同名重复导入时「删了一行还剩一行」与
    // 「删除无效」不可区分。
    if (mounted) {
      _showSnack(t.settings.resourceLibrary.deleted(name: card.name));
    }
    await _reload();
  }

  Future<void> _deleteBook(Worldbook book) async {
    final t = Translations.of(context);
    final confirmed = await _confirmDelete(
      t.settings.resourceLibrary.deleteConfirm(name: book.name),
    );
    if (confirmed != true) return;
    try {
      await ref.read(resourceLibraryRepositoryProvider).deleteWorldbook(
            book.bookId,
          );
    } catch (e) {
      // 同 _deleteCard——失败反馈而非静默逃逸
      if (mounted) {
        _showSnackFloating(
          '${t.intermediate.memoryBrowser.deleteFailed}: $e',
        );
      }
      return;
    }
    // 同 _deleteCard——删除成功补明确反馈
    if (mounted) {
      _showSnack(t.settings.resourceLibrary.deleted(name: book.name));
    }
    await _reload();
  }

  /// 建卡页返回后刷新列表（保存成功会落新资源/覆盖原资源）。
  Future<void> _openAiCreate(DraftKind kind) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ResourceAiPage(kind: kind)),
    );
    if (mounted) await _reload();
  }

  Future<void> _openAiEditCard(CharacterCard card) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ResourceAiPage(
          kind: DraftKind.characterCard,
          targetCardId: card.cardId,
          targetSummary: cardTargetSummary(card.name, card.sourceFormat),
          originalRawJson: card.rawJson,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _openAiEditBook(Worldbook book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ResourceAiPage(
          kind: DraftKind.worldbook,
          targetBookId: book.bookId,
          targetSummary: bookTargetSummary(book.name),
          originalRawJson: book.rawJson,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Future<bool?> _confirmDelete(String message) {
    return showLmDialog<bool>(
      context: context,
      // 破坏性确认不可点屏障关闭——屏障/ESC 与
      // 「取消」关闭后的视觉状态完全一致，任何一次未命中确认键都表现
      // 为「弹窗关了但什么都没发生」（的表象之一）。
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        // 补标题对齐记忆库实体删除弹窗骨架
        title:
            Text(Translations.of(context).settings.resourceLibrary.deleteTitle),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Translations.of(context).common.cancel),
          ),
          // 确认键此前借用模板域键「删除模板」——
          // 在世界书/角色卡删除弹窗域错位；改 common.delete 并按
          // 用破坏性红前景（与记忆库实体删除弹窗同款）。
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(Translations.of(context).common.delete),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(message),
        ),
      );
  }

  /// 新增反馈走浮层 SnackBar（repo 门禁：showSnackBar 必须
  /// floating）。2026-09-06 ：[_showSnack] 已统一浮层，
  /// 与 [_showSnackFloating] 等价（保留后者别名避免连锁改调用点）。
  void _showSnackFloating(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(
        Theme.of(context).scaffoldBackgroundColor,
      ),
      appBar: SimpleAppBar(title: t.settings.resourceLibrary.title),
      // 加载 / 错误（含重试）/ 内容三态
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        t.settings.resourceLibrary.loadFailed,
                        style: SimpleTextStyles.body,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: SimpleSpacing.sMd),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: Text(t.common.retry),
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _errorMessage = null;
                          });
                          _reload();
                        },
                      ),
                    ],
                  ),
                )
              : LmMeasure(
                  maxWidth: LmLayout.listMeasure,
                  child: ListView(
                    padding: const EdgeInsets.all(SimpleSpacing.sLg),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.badge_outlined),
                              label:
                                  Text(t.settings.resourceLibrary.importCard),
                              onPressed: _importCard,
                            ),
                          ),
                          const SizedBox(width: SimpleSpacing.sMd),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.data_object_outlined),
                              // F9 修复：纯 JSON 角色卡应用内入口——
                              // 此前只能靠移动端分享进入，Wiki 却宣称支持
                              label: Text(
                                t.settings.resourceLibrary.importCardJson,
                              ),
                              onPressed: _importCardJson,
                            ),
                          ),
                          const SizedBox(width: SimpleSpacing.sMd),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.auto_stories_outlined),
                              label:
                                  Text(t.settings.resourceLibrary.importBook),
                              onPressed: _importBook,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: SimpleSpacing.sMd),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.auto_awesome_outlined),
                              label: Text(
                                t.settings.resourceLibrary.aiCreateCard,
                              ),
                              onPressed: () =>
                                  _openAiCreate(DraftKind.characterCard),
                            ),
                          ),
                          const SizedBox(width: SimpleSpacing.sMd),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.auto_awesome_outlined),
                              label: Text(
                                t.settings.resourceLibrary.aiCreateBook,
                              ),
                              onPressed: () =>
                                  _openAiCreate(DraftKind.worldbook),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: SimpleSpacing.sLg),
                      _sectionTitle(t.settings.resourceLibrary.cardsSection),
                      if (_cards.isEmpty)
                        Text(t.settings.resourceLibrary.emptyList)
                      else
                        ..._cards.map(
                          (c) => _tile(
                            title: c.name,
                            subtitle: c.sourceFormat ?? 'json',
                            onTap: () => showCardContentSheet(
                              context,
                              name: c.name,
                              rawJson: c.rawJson,
                            ),
                            onEdit: () => _openAiEditCard(c),
                            onDelete: () => _deleteCard(c),
                          ),
                        ),
                      const SizedBox(height: SimpleSpacing.sLg),
                      _sectionTitle(t.settings.resourceLibrary.booksSection),
                      if (_books.isEmpty)
                        Text(t.settings.resourceLibrary.emptyList)
                      else
                        ..._books.map(
                          (b) => _tile(
                            title: b.name,
                            onTap: () => showBookContentSheet(
                              context,
                              name: b.name,
                              rawJson: b.rawJson,
                            ),
                            onEdit: () => _openAiEditBook(b),
                            onDelete: () => _deleteBook(b),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
      child: Text(title, style: SimpleTextStyles.title3),
    );
  }

  Widget _tile({
    required String title,
    required VoidCallback onDelete,
    String? subtitle,
    VoidCallback? onTap,
    VoidCallback? onEdit,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onEdit != null)
            IconButton(
              tooltip: Translations.of(context).settings.resourceLibrary.aiEdit,
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
          IconButton(
            //  语义缺口：复用 common.delete（不新增 i18n key）。
            tooltip: Translations.of(context).common.delete,
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
