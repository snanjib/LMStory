import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/mac_window_close_guard.dart';

/// 关窗拦截 Dart 侧判定链的行为锁：
/// 空闲放行 / 生成中随用户确认 / 确认框重入拒绝 / 判定异常 fail-open。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var busy = false;
  var confirmCalls = 0;
  var confirmResult = true;
  Object? busyError;

  setUp(() {
    MacWindowCloseGuard.resetForTesting();
    busy = false;
    confirmCalls = 0;
    confirmResult = true;
    busyError = null;
    MacWindowCloseGuard.register(
      isBusy: () async {
        if (busyError != null) throw Exception(busyError);
        return busy;
      },
      showConfirm: () async {
        confirmCalls++;
        return confirmResult;
      },
    );
  });

  Future<Object?> requestClose() async {
    const channel = MethodChannel('lmstory/window_close');
    late ByteData? reply;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'lmstory/window_close',
      channel.codec.encodeMethodCall(const MethodCall('requestClose')),
      (data) => reply = data,
    );
    return channel.codec.decodeEnvelope(reply!);
  }

  test('空闲时直接放行，不弹确认框', () async {
    busy = false;
    final result = await requestClose();
    expect(result, <String, dynamic>{'allow': true});
    expect(confirmCalls, 0);
  });

  test('生成中弹确认，用户确认则放行', () async {
    busy = true;
    confirmResult = true;
    final result = await requestClose();
    expect(result, <String, dynamic>{'allow': true});
    expect(confirmCalls, 1);
  });

  test('生成中弹确认，用户留下则拦截', () async {
    busy = true;
    confirmResult = false;
    final result = await requestClose();
    expect(result, <String, dynamic>{'allow': false});
    expect(confirmCalls, 1);
  });

  test('isBusy 抛异常时 fail-open（不让用户关不掉窗口）', () async {
    busyError = StateError('ref disposed');
    final result = await requestClose();
    expect(result, <String, dynamic>{'allow': true});
    expect(confirmCalls, 0);
  });
}
