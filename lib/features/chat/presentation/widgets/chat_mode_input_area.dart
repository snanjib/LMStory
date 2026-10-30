import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/services/file_drop_receiver.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/lm_state_transition.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/utils/file_reader.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_reader_web.dart';
import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';
import 'package:lmstory/features/settings/domain/entities/input_keys.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Maximum number of image attachments per message.
const _maxImageAttachments = 8;

/// Maximum number of file attachments per message.
const _maxFileAttachments = 20;

/// Simple mode chat input area.
///
/// Encapsulated input area with a capsule-shaped text field, an embedded
/// send button, a stop button on the left, and a model selector chip on
/// the right of the toolbar row.
///
/// Enhancements over basic input (Phase 3, ported from ChatBox):
/// - Configurable send key shortcut (Enter vs Ctrl+Enter)
/// - Input history navigation with up/down arrow keys
/// - Toolbar status slot (context usage ring injected by the page)
/// - Image/file attachment support with preview area
/// - Clipboard image paste support
class ChatModeInputArea extends ConsumerStatefulWidget {
  const ChatModeInputArea({
    required this.onSend,
    required this.onCancel,
    required this.isSending,
    required this.isStreaming,
    this.isCompressing = false,
    this.controller,
    this.focusNode,
    this.currentModelName,
    this.currentProviderName,
    this.onModelSelect,
    this.onSessionSettings,
    this.quoteText,
    this.onClearQuote,
    this.sendKey = SendKey.enter,
    this.newlineKey = NewlineKey.shiftEnter,
    this.inputHistory = const [],
    this.contextSlot,
    this.onBeforeSend,
    super.key,
  });

  /// Callback when user sends a message with optional attachments.
  final void Function(String text, List<MessageAttachment> attachments) onSend;
  final VoidCallback onCancel;
  final bool isSending;
  final bool isStreaming;

  /// 发送前预检钩子：返回 false 时
  /// 不清空输入、不发送（草稿会话无预设/模型/Key 等配置错误场景）——
  /// 此前先清空再由控制器拒绝，已打文本与附件原地蒸发不可恢复。
  /// 错误提示由预检方（控制器）自行落错误横幅。
  final Future<bool> Function(String text, List<MessageAttachment> attachments)?
      onBeforeSend;

  /// 是否正在压缩上下文（：压缩窗口内禁用发送——此前发送按钮
  /// 不感知压缩态，先清空输入再被控制器静默吞掉，已打字内容丢失）
  final bool isCompressing;

  /// Optional external TextEditingController. If null, an internal one is created.
  final TextEditingController? controller;

  /// Optional external FocusNode. If null, an internal one is created.
  final FocusNode? focusNode;

  /// Display name of the currently selected model.
  final String? currentModelName;

  /// Display name of the currently selected provider.
  final String? currentProviderName;

  /// Callback when the model selector chip is tapped.
  final VoidCallback? onModelSelect;

  /// Callback when the session settings button is tapped.
  /// Opens the SessionSettingsSheet as a bottom sheet.
  final VoidCallback? onSessionSettings;

  /// 引用文本（非 null 时在输入框上方显示预览块，对标 ChatBox quote preview）
  final String? quoteText;

  /// 清除引用文本的回调（预览块关闭按钮）
  final VoidCallback? onClearQuote;

  /// Send key preference.
  final SendKey sendKey;

  /// Newline key preference (desktop only).
  final NewlineKey newlineKey;

  /// Input history for up/down arrow navigation.
  final List<String> inputHistory;

  /// 输入区工具栏左侧状态插槽（：上下文用量圆环经此注入）。
  ///
  /// core 不依赖 features——圆环组件（story_runtime）由页面组装后传入，
  /// 与故事/导演模式的 InputToolbar.trailing 接线同范式。占位于附件
  /// 按钮之后、会话设置按钮之前（旧 token 徽章的原位置）。
  final Widget? contextSlot;

  @override
  ConsumerState<ChatModeInputArea> createState() => _ChatModeInputAreaState();
}

class _ChatModeInputAreaState extends ConsumerState<ChatModeInputArea> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _ownsController = false;
  bool _ownsFocusNode = false;
  bool _hasText = false;

  /// Current position in input history (-1 = not navigating history).
  int _historyIndex = -1;

  /// Text saved before starting history navigation, to restore on down-arrow.
  String _savedText = '';

  /// Current attachments pending to be sent with the next message.
  final List<MessageAttachment> _attachments = [];

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
      _ownsController = false;
    } else {
      _controller = TextEditingController();
      _ownsController = true;
    }
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
      _ownsFocusNode = false;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
    _hasText = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final hasText = _controller.text.isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  /// 预检在途标志：预检是异步的（读配置/Key），窗口内去抖防双发。
  bool _precheckInFlight = false;

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    final hasText = text.isNotEmpty;
    final hasAttachments = _attachments.isNotEmpty;
    if ((!hasText && !hasAttachments) ||
        widget.isSending ||
        widget.isStreaming ||
        widget.isCompressing ||
        _precheckInFlight) {
      return;
    }
    // 预检先行——失败时输入与附件原地保留（不清空、不发送），
    // 错误横幅由预检方落。此前先清空再被控制器拒绝，长文输入蒸发。
    final precheck = widget.onBeforeSend;
    if (precheck != null) {
      _precheckInFlight = true;
      bool passed;
      try {
        passed = await precheck(text, List.from(_attachments));
      } finally {
        _precheckInFlight = false;
      }
      if (!passed || !mounted) return;
      // 预检等待期间忙态可能翻转（如恰好进入压缩），重查一次
      if (widget.isSending || widget.isStreaming || widget.isCompressing) {
        return;
      }
    }
    _controller.clear();
    _historyIndex = -1;
    _savedText = '';
    final attachments = List<MessageAttachment>.from(_attachments);
    _attachments.clear();
    widget.onSend(text, attachments);
  }

  /// 在光标位置插入换行符（Ctrl+Enter / Alt+Enter 换行时调用）。
  void _insertNewlineAtCursor() {
    final selection = _controller.selection;
    final text = _controller.text;
    final newText = text.replaceRange(selection.start, selection.end, '\n');
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
  }

  /// 判断组合键是否匹配发送键。
  static bool _matchesSendKey(
    SendKey key,
    bool isCtrl,
    bool isShift,
    bool isAlt,
  ) {
    switch (key) {
      case SendKey.enter:
        return !isCtrl && !isShift && !isAlt;
      case SendKey.shiftEnter:
        return isShift && !isCtrl && !isAlt;
      case SendKey.ctrlEnter:
        return isCtrl && !isShift && !isAlt;
      case SendKey.button:
        return false;
    }
  }

  /// 判断组合键是否匹配换行键。
  static bool _matchesNewlineKey(
    NewlineKey key,
    bool isCtrl,
    bool isShift,
    bool isAlt,
  ) {
    switch (key) {
      case NewlineKey.enter:
        return !isCtrl && !isShift && !isAlt;
      case NewlineKey.shiftEnter:
        return isShift && !isCtrl && !isAlt;
      case NewlineKey.ctrlEnter:
        return isCtrl && !isShift && !isAlt;
      case NewlineKey.altEnter:
        return isAlt && !isCtrl && !isShift;
    }
  }

  /// Handle key events for send shortcut and input history navigation.
  ///
  /// Send key and newline key are independently configured (desktop).
  /// Mobile uses SendKey.button (回车换行) or SendKey.enter (回车发送).
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;

    if (isEnter) {
      final isCtrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      final isAlt = HardwareKeyboard.instance.isAltPressed;

      // 匹配发送键
      if (_matchesSendKey(widget.sendKey, isCtrl, isShift, isAlt)) {
        _handleSend();
        return KeyEventResult.handled;
      }

      // 匹配换行键
      if (_matchesNewlineKey(widget.newlineKey, isCtrl, isShift, isAlt)) {
        // Enter 和 Shift+Enter 的默认行为就是换行，返回 ignored 即可
        // Ctrl+Enter 和 Alt+Enter 需要手动插入换行
        if (widget.newlineKey == NewlineKey.ctrlEnter ||
            widget.newlineKey == NewlineKey.altEnter) {
          _insertNewlineAtCursor();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      // 不匹配任何配置的组合键，忽略
      return KeyEventResult.ignored;
    }

    // Arrow Up: navigate to older input history.
    // 仅空输入可「进入」历史导航（ChatBox 行为，避免劫持多行文本内的
    // 光标移动）；一旦已在导航中（_historyIndex >= 0），继续翻旧不受
    // 已召回文本非空影响——否则首次召回后永远翻不动第二条。
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final navigating = _historyIndex >= 0;
      if ((navigating || _controller.text.isEmpty) &&
          widget.inputHistory.isNotEmpty) {
        _navigateHistory(-1);
        return KeyEventResult.handled;
      }
    }

    // Arrow Down: navigate to newer input history / restore saved text.
    // 导航中即可用，不受当前文本是否为空限制。
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyIndex >= 0) {
        _navigateHistory(1);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  /// Navigate input history. Direction: -1 = older (up), +1 = newer (down).
  void _navigateHistory(int direction) {
    final history = widget.inputHistory;
    if (history.isEmpty) return;

    // Save current text when starting history navigation
    if (_historyIndex == -1 && direction == -1) {
      _savedText = _controller.text;
    }

    final newIndex = _historyIndex - direction;
    if (newIndex < 0) {
      // Went past the newest entry — restore saved text
      _historyIndex = -1;
      _controller.text = _savedText;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
      return;
    }
    if (newIndex >= history.length) return;

    _historyIndex = newIndex;
    _controller.text = history[newIndex];
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Attachment handling
  // ---------------------------------------------------------------------------

  /// Show attachment options bottom sheet.
  void _showAttachmentOptions() {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    showLmSheet<void>(
      context: context,
      // 内容已自绘 Handle，关掉琉璃工厂把手避免双把手。
      glassHandle: false,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Padding(
              padding: const EdgeInsets.only(top: LmSpacing.sSm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.faint.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: LmSpacing.sSm),
            // Upload image
            ListTile(
              leading: Icon(Icons.image_outlined, color: colors.ink),
              title: Text(
                t.chat.attachment.uploadImage,
                style: LmUiTextStyles.body.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage();
              },
            ),
            // Select file
            ListTile(
              leading:
                  Icon(Icons.insert_drive_file_outlined, color: colors.ink),
              title: Text(
                t.chat.attachment.selectFile,
                style: LmUiTextStyles.body.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickFile();
              },
            ),
            const SizedBox(height: LmSpacing.sMd),
          ],
        ),
      ),
    );
  }

  /// Pick image from gallery using image_picker.
  Future<void> _pickImage() async {
    final imageCount = _attachments.where((a) => a.isImage).length;
    // 达上限不再静默 no-op——点选
    // 毫无反馈与 / 已修的静默族同病。
    if (imageCount >= _maxImageAttachments) {
      _showAttachmentLimitSnackBar(
        Translations.of(context).chat.attachmentLimit.image(
              count: _maxImageAttachments,
            ),
      );
      return;
    }

    final picker = ImagePicker();
    // iOS 相册权限被拒时 image_picker 抛 PlatformException(photo_access_denied)，
    // 此前未捕获会静默逃逸成无反馈；权限拒绝给专门指引，其余走通用附加失败。
    final XFile? xFile;
    try {
      xFile = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      _showAttachmentLimitSnackBar(
        e.code == 'photo_access_denied'
            ? Translations.of(context).resourceAi.photoPermissionDenied
            : Translations.of(context).resourceAi.attachFailed(error: '$e'),
      );
      return;
    }

    if (xFile == null) return;
    await _addImageAttachmentFromPath(xFile.path, xFile.name);
  }

  /// 从本地文件路径构造图像附件（相册选取与 macOS 拖放共用）。
  ///
  /// 相册路径经 image_picker 压缩（1920/85）；拖放路径为用户磁盘
  /// 原文件（多为已压缩格式，base64 膨胀与文件附件路径一致）。
  Future<void> _addImageAttachmentFromPath(String path, String name) async {
    final imageCount = _attachments.where((a) => a.isImage).length;
    if (imageCount >= _maxImageAttachments) {
      _showAttachmentLimitSnackBar(
        Translations.of(context).chat.attachmentLimit.image(
              count: _maxImageAttachments,
            ),
      );
      return;
    }

    final Uint8List bytes;
    try {
      bytes = await readFileBytesNative(path);
    } catch (_) {
      if (!mounted) return;
      _showAttachmentLimitSnackBar(
        Translations.of(context).resourceAi.attachReadFailed,
      );
      return;
    }
    // 文件对话框/拖放期间页面可能被切走卸载——await 后回 State 前先守卫
    if (!mounted) return;
    final base64Str = base64Encode(bytes);

    // Determine MIME type from extension
    final ext = name.split('.').last.toLowerCase();
    final mimeType = switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => 'image/jpeg',
    };

    setState(() {
      _attachments.add(
        MessageAttachment(
          type: 'image',
          name: name,
          mimeType: mimeType,
          base64Data: base64Str,
          fileSize: bytes.length,
        ),
      );
    });
  }

  /// Pick file using file_picker.
  Future<void> _pickFile() async {
    final fileCount = _attachments.where((a) => a.isFile).length;
    // 同图片路径——上限反馈
    if (fileCount >= _maxFileAttachments) {
      _showAttachmentLimitSnackBar(
        Translations.of(context).chat.attachmentLimit.file(
              count: _maxFileAttachments,
            ),
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles();

    if (result == null || result.files.isEmpty) return;

    // 桌面文件对话框期间页面可能被切走卸载——await 后回 State 前先守卫
    if (!mounted) return;
    final platformFile = result.files.first;
    final fileName = platformFile.name;

    if (!kIsWeb) {
      final filePath = platformFile.path;
      if (filePath == null) return;
      await _addFileAttachmentFromPath(filePath, fileName);
      return;
    }
    // Web 平台无路径，直接用面板给的 bytes
    final webBytes = platformFile.bytes ?? Uint8List(0);
    await _addFileAttachmentFromBytes(webBytes, fileName);
  }

  /// 从本地文件路径构造文件附件（选择面板与 macOS 拖放共用）。
  Future<void> _addFileAttachmentFromPath(String path, String fileName) async {
    final Uint8List bytes;
    try {
      bytes = await readFileBytesNative(path);
    } catch (_) {
      // iCloud 占位未下载/路径失效等读取失败：此前静默逃逸无反馈
      if (!mounted) return;
      _showAttachmentLimitSnackBar(
        Translations.of(context).resourceAi.attachReadFailed,
      );
      return;
    }
    await _addFileAttachmentFromBytes(bytes, fileName);
  }

  /// 字节→文件附件的公共构造（含文本白名单提示与上限检查）。
  Future<void> _addFileAttachmentFromBytes(
    Uint8List bytes,
    String fileName,
  ) async {
    final fileCount = _attachments.where((a) => a.isFile).length;
    if (fileCount >= _maxFileAttachments) {
      _showAttachmentLimitSnackBar(
        Translations.of(context).chat.attachmentLimit.file(
              count: _maxFileAttachments,
            ),
      );
      return;
    }
    if (bytes.isEmpty) return;
    if (!mounted) return;
    final ext = fileName.split('.').last.toLowerCase();

    // Text file extensions that can be read as content
    const textExtensions = {
      'txt',
      'md',
      'csv',
      'json',
      'xml',
      'yaml',
      'yml',
      'html',
      'css',
      'js',
      'ts',
      'py',
      'java',
      'c',
      'cpp',
      'h',
      'sh',
      'bat',
      'sql',
      'log',
      'ini',
      'cfg',
      'toml',
    };

    String? textContent;
    if (textExtensions.contains(ext)) {
      try {
        textContent = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        // Binary file or encoding error — skip text content
      }
    } else {
      // 非白名单文本类型即时提示——附件卡会正常
      // 显示，但当前只有图片与白名单文本能进模型上下文，先说清
      // 「不会发给模型」，消除发送后的静默能力错觉。
      if (mounted) {
        _showAttachmentLimitSnackBar(
          Translations.of(context).chat.attachment.unreadableHint,
        );
      }
    }

    // Determine MIME type
    final mimeType = _mimeTypeFromExtension(ext);

    setState(() {
      _attachments.add(
        MessageAttachment(
          type: 'file',
          name: fileName,
          mimeType: mimeType,
          textContent: textContent,
          fileSize: bytes.length,
        ),
      );
    });
  }

  /// macOS 拖入文件落进会话：图片扩展名走图像附件，其余走文件附件；
  /// 上限与失败反馈复用选择面板同链路，完成后统一提示成功数。
  Future<void> _addDroppedFiles(List<IncomingFile> files) async {
    var added = 0;
    for (final f in files) {
      if (!mounted) return;
      final before = _attachments.length;
      if (FileDropRouting.isImageFile(f.fileName)) {
        await _addImageAttachmentFromPath(f.path, f.fileName);
      } else {
        await _addFileAttachmentFromPath(f.path, f.fileName);
      }
      if (_attachments.length > before) added++;
    }
    if (!mounted || added == 0) return;
    _showAttachmentLimitSnackBar(
      Translations.of(context).chat.attachment.dropAttached(count: added),
    );
  }

  /// Remove an attachment by index.
  void _removeAttachment(int index) {
    setState(() {
      _attachments.removeAt(index);
    });
  }

  /// 附件数量达上限的 floating 反馈。
  void _showAttachmentLimitSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Get MIME type from file extension.
  String _mimeTypeFromExtension(String ext) {
    return switch (ext) {
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      'md' => 'text/markdown',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'xml' => 'application/xml',
      'yaml' || 'yml' => 'text/yaml',
      'html' => 'text/html',
      'css' => 'text/css',
      'js' => 'application/javascript',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'application/octet-stream',
    };
  }

  /// Format file size for display.
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    // macOS 文件拖放→会话附件注入桥：MainLayout 分发后在此消费
    //（构造/上限/失败反馈与选择面板完全同链路）。
    ref.listen<List<IncomingFile>>(pendingDropFilesProvider, (prev, files) {
      if (files.isEmpty) return;
      ref.read(pendingDropFilesProvider.notifier).state = const [];
      _addDroppedFiles(files);
    });
    //  修复：生成过程中保持输入框可输入，
    // 让用户可以提前编辑下次准备发送的内容。仅禁用发送按钮（canSend）。
    // 原逻辑：isInputEnabled = !widget.isSending && !widget.isStreaming（完全禁用输入框）
    // 新逻辑：输入框始终 enabled，仅发送按钮根据 isSending/isStreaming 禁用
    final isBusy =
        widget.isSending || widget.isStreaming || widget.isCompressing;
    final hasText = _hasText;
    final hasAttachments = _attachments.isNotEmpty;
    final canSend = !isBusy && (hasText || hasAttachments);

    return context.lmUi.inputArea(
      context,
      // 条带本身（底色 + 顶部分隔线）通铺整窗——这是输入区作为「chrome」的
      // 形态；内容列则与正文同版心（见下方 LmMeasure），否则宽屏下正文 720
      // 居中、输入框通铺整窗（2560 窗口下 2320），左右留白完全失衡。
      SafeArea(
        top: false,
        child: LmMeasure(
          maxWidth: LmLayout.readingMeasure,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              LmSpacing.sMd,
              LmSpacing.sSm,
              LmSpacing.sMd,
              LmSpacing.sMd,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Quote preview bar (对标 ChatBox quote preview)
                if (widget.quoteText != null && widget.quoteText!.isNotEmpty)
                  _buildQuotePreview(colors, t),
                // Attachment preview area
                if (hasAttachments) _buildAttachmentPreview(colors, t),
                // Text input row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _buildLeftButton(colors),
                    const SizedBox(width: LmSpacing.sSm),
                    Expanded(
                      child: Container(
                        //  修复：maxHeight 120→200，提升屏占比
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: Focus(
                          onKeyEvent: _handleKeyEvent,
                          child: TextField(
                            focusNode: _focusNode,
                            controller: _controller,
                            enabled: true,
                            maxLines: null,
                            //  修复：生成中时 Enter 改为换行，
                            // 避免按 Enter 触发 onSubmitted 导致键盘收起但不发送
                            // 非生成中时：Enter 模式下 Enter 发送，其他模式 Enter 换行
                            textInputAction: isBusy
                                ? TextInputAction.newline
                                : (widget.sendKey == SendKey.enter
                                    ? TextInputAction.send
                                    : TextInputAction.newline),
                            onSubmitted:
                                (!isBusy && widget.sendKey == SendKey.enter)
                                    ? (_) => _handleSend()
                                    : null,
                            style: LmUiTextStyles.body.copyWith(
                              color: colors.ink,
                            ),
                            decoration: InputDecoration(
                              hintText: t.chat.messageHint,
                              filled: true,
                              fillColor: Colors.transparent,
                              //  修复：优化 padding 提升屏占比
                              contentPadding: const EdgeInsets.fromLTRB(
                                LmSpacing.sMd,
                                12,
                                4,
                                12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  context.lmUi.radius(LmCorner.md),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  context.lmUi.radius(LmCorner.md),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              disabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  context.lmUi.radius(LmCorner.md),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  context.lmUi.radius(LmCorner.md),
                                ),
                                borderSide: BorderSide(
                                  color: colors.primary,
                                  width: 1.5,
                                ),
                              ),
                              suffixIcon: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: _buildSendButton(
                                  canSend,
                                  colors,
                                  t,
                                ),
                              ),
                              suffixIconConstraints: const BoxConstraints(
                                minWidth: 44,
                                minHeight: 44,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Toolbar row: attachment button + context status slot (left) + settings + model selector (right)
                Padding(
                  padding: const EdgeInsets.only(top: LmSpacing.sXs),
                  child: Row(
                    children: [
                      // Attachment button (+ icon)
                      if (!widget.isStreaming)
                        _AttachmentButton(
                          onPressed: _showAttachmentOptions,
                          colors: colors,
                        ),
                      const SizedBox(width: LmSpacing.sXs),
                      // 上下文用量圆环（页面注入的状态插槽，替换旧文本徽章）
                      if (widget.contextSlot != null) ...[
                        widget.contextSlot!,
                        const SizedBox(width: LmSpacing.sXs),
                      ],
                      // Session settings button (gear icon)
                      if (widget.onSessionSettings != null)
                        _SessionSettingsButton(
                          onPressed: widget.onSessionSettings!,
                          colors: colors,
                        ),
                      if (widget.onSessionSettings != null &&
                          widget.onModelSelect != null)
                        const SizedBox(width: LmSpacing.sXs),
                      // Model selector chip —— Flexible 包裹，空间不足时可收缩，
                      // 内部 Text 走 ellipsis + 长按 Tooltip 兜底，避免 overflow。
                      if (widget.onModelSelect != null)
                        Flexible(
                          child: _ModelSelectorChip(
                            modelName: widget.currentModelName,
                            providerName: widget.currentProviderName,
                            onTap: widget.onModelSelect!,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build the quote preview bar shown above the attachment area.
  ///
  /// 对标 ChatBox quote preview：显示引用文本前 100 字符 + '...' + 关闭按钮。
  /// 引用文本在发送时格式化为 markdown 引用块拼接到用户输入前。
  Widget _buildQuotePreview(LmPalette colors, Translations t) {
    final raw = widget.quoteText ?? '';
    // 预览只显示前 100 字符，超出部分用 '...' 表示
    final preview = raw.length > 100 ? '${raw.substring(0, 100)}...' : raw;
    // 单行显示，内部换行替换为空格
    final singleLine = preview.replaceAll(RegExp(r'\s+'), ' ');

    return Container(
      margin: const EdgeInsets.only(bottom: LmSpacing.sXs),
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.sXs,
      ),
      // 遵循 impeccable 规则：用背景色 tint 替代侧边条 border（避免 AI 默认审美）
      // accentDim 为 accent 色 12% opacity，配合 format_quote 图标传达"引用"语义
      decoration: BoxDecoration(
        color: colors.accentDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.format_quote,
            size: 14,
            color: colors.accent,
          ),
          const SizedBox(width: LmSpacing.sXs),
          Expanded(
            child: Text(
              singleLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LmUiTextStyles.caption.copyWith(
                color: colors.muted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          if (widget.onClearQuote != null)
            // 纯图标可点控件：补 button 角色 + 可读名（语义补完）
            Semantics(
              button: true,
              label: t.common.clear,
              child: InkWell(
                onTap: widget.onClearQuote,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                child: Padding(
                  padding: const EdgeInsets.all(LmSpacing.s2xs),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: colors.faint,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Build the attachment preview area shown above the text input.
  Widget _buildAttachmentPreview(LmPalette colors, Translations t) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 120),
      margin: const EdgeInsets.only(bottom: LmSpacing.sXs),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(_attachments.length, (i) {
            final attachment = _attachments[i];
            return Padding(
              padding: const EdgeInsets.only(right: LmSpacing.sXs),
              child: attachment.isImage
                  ? _ImagePreviewCard(
                      attachment: attachment,
                      onRemove: () => _removeAttachment(i),
                      colors: colors,
                    )
                  : _FilePreviewCard(
                      attachment: attachment,
                      onRemove: () => _removeAttachment(i),
                      colors: colors,
                      fileSizeFormatter: _formatFileSize,
                    ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildLeftButton(LmPalette colors) {
    // 压缩中同样显示停止键——复用生成停止位
    if (widget.isStreaming || widget.isCompressing) {
      return _StopButton(
        onPressed: widget.onCancel,
        colors: colors,
      );
    }
    return const SizedBox(width: 44);
  }

  Widget _buildSendButton(
    bool canSend,
    LmPalette colors,
    Translations t,
  ) {
    return LmStateTransition(
      stateKey: widget.isSending || widget.isStreaming,
      alignment: Alignment.center,
      child: _buildSendButtonContent(canSend, colors, t),
    );
  }

  Widget _buildSendButtonContent(
    bool canSend,
    LmPalette colors,
    Translations t,
  ) {
    if (widget.isSending || widget.isStreaming) {
      return SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.faint,
            ),
          ),
        ),
      );
    }

    return IconButton(
      icon: const Icon(Icons.send_rounded, size: 20),
      color: canSend ? colors.primary : colors.faint,
      onPressed: canSend ? _handleSend : null,
      onLongPress: _insertNewlineAtCursor,
      padding: EdgeInsets.zero,
      // P0-E 修复：触控目标 ≥44x44（移动端可访问性规范）
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      style: IconButton.styleFrom(
        backgroundColor: canSend ? colors.primaryDim : Colors.transparent,
        shape: const CircleBorder(),
      ),
      tooltip: t.chat.send,
    );
  }
}

// =============================================================================
// Attachment button (+ icon)
// =============================================================================

class _AttachmentButton extends StatelessWidget {
  const _AttachmentButton({
    required this.onPressed,
    required this.colors,
  });

  final VoidCallback? onPressed;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Tooltip(
      message: t.chat.attachment.add,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        child: Padding(
          // 扩大点击区域至 44x44（满足 WCAG 触控目标要求）
          padding: const EdgeInsets.all(8),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.add_rounded,
              size: 18,
              color: onPressed != null ? colors.muted : colors.faint,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Session settings button (gear icon)
// =============================================================================

class _SessionSettingsButton extends StatelessWidget {
  const _SessionSettingsButton({
    required this.onPressed,
    required this.colors,
  });

  final VoidCallback onPressed;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Tooltip(
      message: t.chat.sessionSettings.title,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        child: Padding(
          // 扩大点击区域至 44x44（满足 WCAG 触控目标要求）
          padding: const EdgeInsets.all(8),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.tune,
              size: 16,
              color: colors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Image preview card
// =============================================================================

class _ImagePreviewCard extends StatelessWidget {
  const _ImagePreviewCard({
    required this.attachment,
    required this.onRemove,
    required this.colors,
  });

  final MessageAttachment attachment;
  final VoidCallback onRemove;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            border: Border.all(color: colors.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: attachment.base64Data != null
              ? Image.memory(
                  base64Decode(attachment.base64Data!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.broken_image_outlined,
                    size: 20,
                    color: colors.faint,
                  ),
                )
              : Icon(
                  Icons.image_outlined,
                  size: 20,
                  color: colors.faint,
                ),
        ),
        // Remove button
        Positioned(
          right: -4,
          top: -4,
          // 纯图标可点控件：补 button 角色 + 可读名（语义补完）
          child: Semantics(
            button: true,
            label: t.common.removeAttachment,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: colors.surfaceElevated,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.divider, width: 0.5),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.close,
                  size: 10,
                  color: colors.muted,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// File preview card
// =============================================================================

class _FilePreviewCard extends StatelessWidget {
  const _FilePreviewCard({
    required this.attachment,
    required this.onRemove,
    required this.colors,
    required this.fileSizeFormatter,
  });

  final MessageAttachment attachment;
  final VoidCallback onRemove;
  final LmPalette colors;
  final String Function(int) fileSizeFormatter;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sSm,
            vertical: LmSpacing.s2xs,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            border: Border.all(color: colors.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 18,
                color: colors.muted,
              ),
              const SizedBox(width: LmSpacing.s2xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      attachment.name ?? 'File',
                      style: LmUiTextStyles.caption.copyWith(
                        color: colors.ink,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    if (attachment.fileSize != null)
                      Text(
                        fileSizeFormatter(attachment.fileSize!),
                        style: LmUiTextStyles.overline.copyWith(
                          color: colors.faint,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Remove button
        Positioned(
          right: -4,
          top: -4,
          // 纯图标可点控件：补 button 角色 + 可读名（语义补完）
          child: Semantics(
            button: true,
            label: t.common.removeAttachment,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: colors.surfaceElevated,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.divider, width: 0.5),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.close,
                  size: 10,
                  color: colors.muted,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Stop button
// =============================================================================

class _StopButton extends StatelessWidget {
  const _StopButton({
    required this.onPressed,
    required this.colors,
  });

  final VoidCallback onPressed;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: colors.accentDim,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.stop_rounded, size: 18),
        color: colors.accent,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        // P0-E 修复：触控目标 ≥44x44（移动端可访问性规范）
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        tooltip: t.chat.stop,
      ),
    );
  }
}

// =============================================================================
// Model selector chip
// =============================================================================

class _ModelSelectorChip extends StatelessWidget {
  const _ModelSelectorChip({
    required this.onTap,
    this.modelName,
    this.providerName,
  });

  final VoidCallback onTap;
  final String? modelName;
  final String? providerName;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final hasModel = modelName != null && modelName!.isNotEmpty;

    final tooltipMessage = hasModel
        ? (providerName != null && providerName!.isNotEmpty
            ? '$modelName · $providerName'
            : modelName!)
        : t.chat.modelSelector.noModel;

    return Material(
      color: colors.surfaceVariant,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        child: Tooltip(
          message: tooltipMessage,
          // 长按显示完整模型名（含供应商）；点击则触发 onTap 打开选择菜单。
          // 不可设为 TooltipTriggerMode.tap，否则 Tooltip 会拦截点击事件，
          // 导致 InkWell.onTap 不触发（表现为白框显示文字而非弹出菜单）。
          triggerMode: TooltipTriggerMode.longPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LmSpacing.sSm,
              vertical: LmSpacing.s3xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  size: 14,
                  color: hasModel ? colors.muted : colors.faint,
                ),
                const SizedBox(width: LmSpacing.s2xs),
                // 固定最大宽度 + ellipsis + 长按 Tooltip 兜底：
                // 长模型名也不会出现 RenderFlex overflow 错误。
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      hasModel ? modelName! : t.chat.modelSelector.noModel,
                      style: LmUiTextStyles.overline.copyWith(
                        color: hasModel ? colors.muted : colors.faint,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: hasModel ? colors.muted : colors.faint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
