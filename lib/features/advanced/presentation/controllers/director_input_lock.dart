import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 导演会话输入锁：将输入框固定为不可编辑文本，仅允许用户亲自点击
/// 发送（发送本身不受锁影响，不自动发送）。
///
/// 通用能力（无演示语义）：任何需要固定输入的场景（如教学、模板
/// 引导）均可设置；根作用域缺省 null=无锁，演示作用域经
/// overrideWithValue 注入。锁存在期间宿主页面须同时挡住草稿恢复、
/// 草稿落库与工具栏插入（见 advanced_chat_page 消费点）。
class DirectorInputLock {
  const DirectorInputLock({required this.fixedText});

  /// 固定呈现的文本（发送时按此原文发出）
  final String fixedText;
}

class DirectorInputLockController extends ValueNotifier<DirectorInputLock?> {
  DirectorInputLockController([super.initial]);

  void lockTo(String fixedText) =>
      value = DirectorInputLock(fixedText: fixedText);

  void release() => value = null;
}

/// 根作用域缺省无锁。演示作用域 override 为桥内实例。
final directorInputLockProvider = Provider<DirectorInputLockController>(
  (ref) => DirectorInputLockController(),
);
