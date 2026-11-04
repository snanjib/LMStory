import 'dart:convert';

/// 消息附件实体
///
/// 表示聊天消息中的附件（图片或文件）。
/// 存储为 JSON 字符串在数据库的 attachments 列中。
class MessageAttachment {
  const MessageAttachment({
    required this.type,
    this.name,
    this.mimeType,
    this.base64Data,
    this.textContent,
    this.fileSize,
  });

  /// 从 Map 反序列化
  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      type: json['type'] as String,
      name: json['name'] as String?,
      mimeType: json['mimeType'] as String?,
      base64Data: json['base64Data'] as String?,
      textContent: json['textContent'] as String?,
      fileSize: json['fileSize'] as int?,
    );
  }

  /// 附件类型：'image' 或 'file'
  final String type;

  /// 文件名
  final String? name;

  /// MIME 类型（如 image/jpeg, text/plain）
  final String? mimeType;

  /// 图片的 base64 编码数据（用于图片附件）
  final String? base64Data;

  /// 文件的文本内容（用于文本文件附件）
  final String? textContent;

  /// 文件大小（字节）
  final int? fileSize;

  /// 从 JSON 字符串列表反序列化
  static List<MessageAttachment> listFromJson(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return const [];
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => MessageAttachment.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 将附件列表序列化为 JSON 字符串
  static String listToJson(List<MessageAttachment> attachments) {
    if (attachments.isEmpty) return '';
    return jsonEncode(attachments.map((a) => a.toJson()).toList());
  }

  /// 序列化为 Map
  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (name != null) 'name': name,
      if (mimeType != null) 'mimeType': mimeType,
      if (base64Data != null) 'base64Data': base64Data,
      if (textContent != null) 'textContent': textContent,
      if (fileSize != null) 'fileSize': fileSize,
    };
  }

  /// 是否为图片附件
  bool get isImage => type == 'image';

  /// 是否为文件附件
  bool get isFile => type == 'file';

  MessageAttachment copyWith({
    String? type,
    String? name,
    String? mimeType,
    String? base64Data,
    String? textContent,
    int? fileSize,
  }) {
    return MessageAttachment(
      type: type ?? this.type,
      name: name ?? this.name,
      mimeType: mimeType ?? this.mimeType,
      base64Data: base64Data ?? this.base64Data,
      textContent: textContent ?? this.textContent,
      fileSize: fileSize ?? this.fileSize,
    );
  }
}
