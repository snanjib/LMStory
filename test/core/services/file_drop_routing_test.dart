import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/services/file_drop_receiver.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';

/// 拖放分发策略的行为锁：
/// - 对话会话中任意文件都可作附件（识图模型场景拖 PDF/文档）
/// - 其他场景仅 PNG/JSON 走资源导入（角色卡/世界书/备份）
/// - 其余类型提示不支持
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('onDrop 通道事件解析为文件列表（多文件+缺名兜底）', () async {
    final receiver = FileDropReceiver();
    addTearDown(receiver.dispose);
    List<IncomingFile>? got;
    receiver.onFiles = (files) => got = files;
    await receiver.init();

    const channel = MethodChannel('lmstory/file_drop');
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'lmstory/file_drop',
      channel.codec.encodeMethodCall(
        const MethodCall(
          'onDrop',
          {
            'paths': ['/tmp/a.png', '/tmp/notes.txt'],
            'fileNames': ['a.png'],
          },
        ),
      ),
      (_) {},
    );

    expect(got?.length, 2);
    expect(got![0].path, '/tmp/a.png');
    expect(got![0].fileName, 'a.png');
    // 原生缺名时以路径兜底
    expect(got![1].fileName, '/tmp/notes.txt');
  });

  test('onDragActive 切换拖悬状态', () async {
    final receiver = FileDropReceiver();
    addTearDown(receiver.dispose);
    await receiver.init();
    expect(receiver.dragActive.value, isFalse);

    const channel = MethodChannel('lmstory/file_drop');
    Future<void> sendActive({required bool v}) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'lmstory/file_drop',
        channel.codec.encodeMethodCall(
          MethodCall(
            'onDragActive',
            {'active': v},
          ),
        ),
        (_) {},
      );
    }

    await sendActive(v: true);
    expect(receiver.dragActive.value, isTrue);
    await sendActive(v: false);
    expect(receiver.dragActive.value, isFalse);
  });

  test('对话会话中：任意类型都作为附件', () {
    final actions = FileDropRouting.route(
      inChatSession: true,
      fileNames: ['a.png', 'b.pdf', 'c.txt', 'd', 'e.JPG'],
    );
    expect(
      actions,
      everyElement(FileDropAction.attachment),
    );
  });

  test('非会话：PNG/JSON 走导入，其余不支持', () {
    final actions = FileDropRouting.route(
      inChatSession: false,
      fileNames: ['card.png', 'book.json', 'paper.pdf', 'notes.txt', 'noext'],
    );
    expect(actions, [
      FileDropAction.import,
      FileDropAction.import,
      FileDropAction.unsupported,
      FileDropAction.unsupported,
      FileDropAction.unsupported,
    ]);
  });

  test('图片扩展名判定大小写不敏感且含 bmp', () {
    expect(FileDropRouting.isImageFile('photo.JPG'), isTrue);
    expect(FileDropRouting.isImageFile('x.bmp'), isTrue);
    expect(FileDropRouting.isImageFile('y.webp'), isTrue);
    expect(FileDropRouting.isImageFile('z.pdf'), isFalse);
    // 与拖入附件构造的分流一致性：png 同时是图片与可导入
    expect(FileDropRouting.isImageFile('c.png'), isTrue);
    expect(FileDropRouting.isImportableFile('c.png'), isTrue);
  });
}
