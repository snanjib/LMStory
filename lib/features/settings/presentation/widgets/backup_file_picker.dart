import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:lmstory/core/utils/file_reader.dart'
    if (dart.library.js_interop) 'package:lmstory/core/utils/file_reader_web.dart';

Future<({String name, String content})?> pickBackupFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['json'],
    withData: kIsWeb,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.single;
  if (kIsWeb) {
    final bytes = file.bytes;
    if (bytes == null) throw const FormatException('Backup could not be read');
    return (name: file.name, content: utf8.decode(bytes, allowMalformed: true));
  }
  final path = file.path;
  if (path == null) throw const FormatException('Backup could not be read');
  return (name: file.name, content: await readFileContentNative(path));
}
