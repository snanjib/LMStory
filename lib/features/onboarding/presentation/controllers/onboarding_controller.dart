import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';

/// 新手引导状态管理（2026-07-20 新增）
///
/// 职责：
/// - 启动时检测是否已完成引导（SharedPreferences key `onboarding_completed`）
/// - 标记引导完成（首次启动看完或跳过后调用，写入持久化）
///
/// 不负责"重看"模式：从设置主页进入 OnboardingPage 时，传 `isReview: true`，
/// 完成按钮不调用 markCompleted，避免无意义的写入。
///
/// 集成点：
/// - MainLayout 启动时 watch 本 provider，未完成则全屏覆盖 OnboardingPage
/// - SettingsPage 底部「新手引导」入口卡片，点击 push OnboardingPage（review 模式）
class OnboardingState {
  const OnboardingState({
    this.isLoading = true,
    this.completed = false,
  });

  /// 是否仍在加载持久化状态
  final bool isLoading;

  /// 是否已完成引导（首次启动看完或跳过）
  final bool completed;

  OnboardingState copyWith({bool? isLoading, bool? completed}) {
    return OnboardingState(
      isLoading: isLoading ?? this.isLoading,
      completed: completed ?? this.completed,
    );
  }
}

class OnboardingNotifier extends StateNotifier<OnboardingState> {
  OnboardingNotifier(this._prefs) : super(const OnboardingState()) {
    _load();
  }

  final Preferences _prefs;

  /// SharedPreferences 持久化 key
  static const String kCompletedKey = 'onboarding_completed';

  Future<void> _load() async {
    final completed = await _prefs.getBool(kCompletedKey) ?? false;
    if (mounted) {
      state = OnboardingState(isLoading: false, completed: completed);
    }
  }

  /// 标记引导完成（首次启动看完或跳过时调用）
  Future<void> markCompleted() async {
    await _prefs.setBool(kCompletedKey, true);
    if (mounted) {
      state = state.copyWith(isLoading: false, completed: true);
    }
  }
}

/// Onboarding 状态 Provider
///
/// MainLayout 启动时 `ref.watch(onboardingProvider)`：
/// - `state.isLoading == true`：显示空白启动屏（避免引导未加载完显示主界面闪烁）
/// - `state.isLoading == false && !state.completed`：全屏覆盖 OnboardingPage
/// - `state.isLoading == false && state.completed`：正常显示主界面
final onboardingProvider =
    StateNotifierProvider<OnboardingNotifier, OnboardingState>(
  (ref) => OnboardingNotifier(ref.read(preferencesProvider)),
);
