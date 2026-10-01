import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';
import 'package:lmstory/i18n/strings.g.dart';

// =============================================================================
// Attachment preview in message bubble
// （从 simple_message_bubble.dart 拆出，内容区引用）
// =============================================================================

/// Displays image thumbnails and file cards for message attachments.
///
/// Reference: ChatBox's attachment rendering in chat messages.
/// Images are shown as small thumbnails that can be tapped for full-screen view.
/// Files are shown as compact cards with filename and size.
class BubbleAttachmentPreview extends StatelessWidget {
  const BubbleAttachmentPreview({
    required this.attachments,
    required this.isUser,
    required this.colors,
    super.key,
  });

  final List<MessageAttachment> attachments;
  final bool isUser;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final imageAttachments = attachments.where((a) => a.isImage).toList();
    final fileAttachments = attachments.where((a) => a.isFile).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: LmSpacing.sXs),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Image grid
          if (imageAttachments.isNotEmpty)
            _ImageGrid(
              images: imageAttachments,
              isUser: isUser,
              colors: colors,
            ),
          // File list
          if (fileAttachments.isNotEmpty)
            _FileList(
              files: fileAttachments,
              isUser: isUser,
              colors: colors,
            ),
        ],
      ),
    );
  }
}

/// 缓存 base64 解码结果的图片组件。
///
/// 在 initState 中一次性解码 base64 并缓存 [MemoryImage] 实例，
/// 后续 rebuild 复用同一实例，确保 Flutter 图片缓存命中，
/// 避免父组件 rebuild 时（如点击切换操作按钮）重新解码导致的闪烁。
class _CachedMemoryImage extends StatefulWidget {
  const _CachedMemoryImage({
    required this.base64Data,
    this.fit,
    this.errorBuilder,
  });

  final String base64Data;
  final BoxFit? fit;
  final Widget Function(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  )? errorBuilder;

  @override
  State<_CachedMemoryImage> createState() => _CachedMemoryImageState();
}

class _CachedMemoryImageState extends State<_CachedMemoryImage> {
  MemoryImage? _imageProvider;
  late Object? _decodeError;

  @override
  void initState() {
    super.initState();
    try {
      _imageProvider = MemoryImage(base64Decode(widget.base64Data));
    } catch (e) {
      _decodeError = e;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageProvider == null) {
      return widget.errorBuilder?.call(context, _decodeError!, null) ??
          const SizedBox.shrink();
    }
    return Image(
      image: _imageProvider!,
      fit: widget.fit,
      errorBuilder: widget.errorBuilder,
    );
  }
}

/// Grid of image thumbnails in a message bubble.
class _ImageGrid extends StatelessWidget {
  const _ImageGrid({
    required this.images,
    required this.isUser,
    required this.colors,
  });

  final List<MessageAttachment> images;
  final bool isUser;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    // Single image: larger display
    if (images.length == 1) {
      return _SingleImage(
        attachment: images.first,
        isUser: isUser,
        colors: colors,
      );
    }

    // Multiple images: grid layout
    return Wrap(
      spacing: LmSpacing.s2xs,
      runSpacing: LmSpacing.s2xs,
      children: [
        for (final image in images)
          _SmallImageThumbnail(
            attachment: image,
            isUser: isUser,
            colors: colors,
          ),
      ],
    );
  }
}

/// Single image display (larger, with max constraints).
class _SingleImage extends StatelessWidget {
  const _SingleImage({
    required this.attachment,
    required this.isUser,
    required this.colors,
  });

  final MessageAttachment attachment;
  final bool isUser;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    // 纯图标可点控件：补 button 角色 + 可读名（语义补完）
    return Semantics(
      button: true,
      label: t.common.viewFullImage,
      child: GestureDetector(
        onTap: () => _showFullScreenImage(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 180),
            child: attachment.base64Data != null
                ? _CachedMemoryImage(
                    base64Data: attachment.base64Data!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildPlaceholder(),
                  )
                : _buildPlaceholder(),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 120,
      height: 80,
      decoration: BoxDecoration(
        color: isUser
            ? colors.onPrimary.withValues(alpha: 0.2)
            : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(LmRadius.rSm),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        size: 24,
        color: isUser ? colors.onPrimary.withValues(alpha: 0.54) : colors.faint,
      ),
    );
  }

  void _showFullScreenImage(BuildContext context) {
    if (attachment.base64Data == null) return;

    final t = Translations.of(context);
    showLmDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.memory(
                  base64Decode(attachment.base64Data!),
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: t.common.close,
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small image thumbnail for multi-image grid.
class _SmallImageThumbnail extends StatelessWidget {
  const _SmallImageThumbnail({
    required this.attachment,
    required this.isUser,
    required this.colors,
  });

  final MessageAttachment attachment;
  final bool isUser;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    // 纯图标可点控件：补 button 角色 + 可读名（语义补完）
    return Semantics(
      button: true,
      label: t.common.viewFullImage,
      child: GestureDetector(
        onTap: () => _showFullScreenImage(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: isUser
                  ? colors.onPrimary.withValues(alpha: 0.2)
                  : colors.surfaceVariant,
            ),
            child: attachment.base64Data != null
                ? _CachedMemoryImage(
                    base64Data: attachment.base64Data!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.broken_image_outlined,
                      size: 20,
                      color: isUser
                          ? colors.onPrimary.withValues(alpha: 0.54)
                          : colors.faint,
                    ),
                  )
                : Icon(
                    Icons.image_outlined,
                    size: 20,
                    color: isUser
                        ? colors.onPrimary.withValues(alpha: 0.54)
                        : colors.faint,
                  ),
          ),
        ),
      ),
    );
  }

  void _showFullScreenImage(BuildContext context) {
    if (attachment.base64Data == null) return;

    final t = Translations.of(context);
    showLmDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.memory(
                  base64Decode(attachment.base64Data!),
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: t.common.close,
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// File list display in a message bubble.
class _FileList extends StatelessWidget {
  const _FileList({
    required this.files,
    required this.isUser,
    required this.colors,
  });

  final List<MessageAttachment> files;
  final bool isUser;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        for (final file in files)
          _FileCard(
            attachment: file,
            isUser: isUser,
            colors: colors,
          ),
      ],
    );
  }
}

/// Compact file card showing filename and size.
class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.attachment,
    required this.isUser,
    required this.colors,
  });

  final MessageAttachment attachment;
  final bool isUser;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: LmSpacing.s2xs),
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: isUser
            ? colors.onPrimary.withValues(alpha: 0.15)
            : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: isUser
            ? Border.all(
                color: colors.onPrimary.withValues(alpha: 0.2),
              )
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _fileIcon,
            size: 18,
            color:
                isUser ? colors.onPrimary.withValues(alpha: 0.7) : colors.muted,
          ),
          const SizedBox(width: LmSpacing.sXs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.name ?? 'File',
                  style: LmUiTextStyles.caption.copyWith(
                    color: isUser ? colors.onPrimary : colors.ink,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                if (attachment.fileSize != null)
                  Text(
                    _formatFileSize(attachment.fileSize!),
                    style: LmUiTextStyles.overline.copyWith(
                      color: isUser
                          ? colors.onPrimary.withValues(alpha: 0.6)
                          : colors.faint,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData get _fileIcon {
    final ext = attachment.name?.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'txt' || 'md' => Icons.description_outlined,
      'json' || 'xml' || 'yaml' || 'yml' => Icons.data_object_outlined,
      'csv' => Icons.table_chart_outlined,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
