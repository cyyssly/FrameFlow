import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/services/image_formats.dart';
import 'package:frame_flow/services/open_image_from_path.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 单实例支持：第二个实例会把图片路径转发给已运行的实例。
///
/// 原生侧（windows/runner）用命名互斥量阻止第二个窗口创建，并通过
/// WM_COPYDATA + MethodChannel 把路径送进来；这里负责导航到播放页。
class SingleInstanceService {
  SingleInstanceService._();

  static final SingleInstanceService instance = SingleInstanceService._();

  static const MethodChannel _channel = MethodChannel(
    'frameflow/single_instance',
  );

  GlobalKey<NavigatorState>? _navigatorKey;
  SlideProvider? _slideProvider;
  SettingsProvider? _settingsProvider;
  String? _pendingPath;

  // 同一个路径可能同时来自实时回调与 takePendingPath，做一次短时去重
  String? _lastOpenedPath;
  DateTime? _lastOpenedAt;

  /// 尽早注册通道，避免第二个实例在 Dart 尚未就绪时发送的路径被丢弃。
  void initializeChannel() {
    if (!Platform.isWindows) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'open') return null;
      final path = call.arguments;
      if (path is String && path.isNotEmpty) _handle(path);
      return null;
    });
  }

  /// runApp 之后调用：绑定导航与播放状态，并补取启动早期收到的路径。
  Future<void> attach({
    required GlobalKey<NavigatorState> navigatorKey,
    required SlideProvider slideProvider,
    required SettingsProvider settingsProvider,
  }) async {
    if (!Platform.isWindows) return;
    _navigatorKey = navigatorKey;
    _slideProvider = slideProvider;
    _settingsProvider = settingsProvider;

    final queued = _pendingPath;
    _pendingPath = null;
    if (queued != null) _handle(queued);

    try {
      final nativePending = await _channel.invokeMethod<String>(
        'takePendingPath',
      );
      if (nativePending != null && nativePending.isNotEmpty) {
        _handle(nativePending);
      }
    } catch (_) {
      // 通道不可用时忽略，不影响正常启动
    }
  }

  void _handle(String path) {
    final navigator = _navigatorKey?.currentState;
    final slide = _slideProvider;
    final settings = _settingsProvider;
    if (navigator == null || slide == null || settings == null) {
      // Dart 还没准备好导航，先暂存
      _pendingPath = path;
      return;
    }
    if (!isSupportedImagePath(path) || !File(path).existsSync()) return;

    final now = DateTime.now();
    if (_lastOpenedPath == path &&
        _lastOpenedAt != null &&
        now.difference(_lastOpenedAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastOpenedPath = path;
    _lastOpenedAt = now;

    _openImage(navigator, slide, settings, path);
  }

  Future<void> _openImage(
    NavigatorState navigator,
    SlideProvider slide,
    SettingsProvider settings,
    String path,
  ) async {
    // 应用可能收在托盘里，先恢复并聚焦窗口
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // 非桌面环境或窗口管理器未初始化时忽略
    }
    if (!navigator.mounted) return;

    await OpenImageFromPath.openImage(
      navigator: navigator,
      slideProvider: slide,
      settings: settings,
      imagePath: path,
      popFirst: true,
    );
  }
}
