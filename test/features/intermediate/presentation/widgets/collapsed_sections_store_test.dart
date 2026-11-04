import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsed_sections_store.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

/// CollapsedSectionsStore 测试（DOC-14 §3.4）。
class _FakeSettingsRepository implements SettingsRepository {
  Map<String, dynamic> overrides = <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> getUserOverrides() async =>
      Map<String, dynamic>.of(overrides);

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

void main() {
  test('默认无记录时返回空集合', () async {
    final store = CollapsedSectionsStore(_FakeSettingsRepository());
    expect(await store.load(), isEmpty);
  });

  test('save 后 load 回读一致的 id 集合', () async {
    final repo = _FakeSettingsRepository();
    final store = CollapsedSectionsStore(repo);

    await store.save({'generation', 'contextBudget'});
    final loaded = await store.load();

    expect(loaded, {'generation', 'contextBudget'});
  });

  test('save 空集合等价于清空折叠记录', () async {
    final repo = _FakeSettingsRepository();
    final store = CollapsedSectionsStore(repo);

    await store.save({'generation'});
    await store.save(<String>{});

    expect(await store.load(), isEmpty);
  });

  test('忽略非 List 的脏数据，返回空集合', () async {
    final repo = _FakeSettingsRepository();
    repo.overrides[CollapsedSectionsStore.key] = 'not-a-list';
    final store = CollapsedSectionsStore(repo);

    expect(await store.load(), isEmpty);
  });
}
