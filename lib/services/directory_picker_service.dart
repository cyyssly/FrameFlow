import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// 目录选择服务
///
/// 统一封装各平台的原生目录选择对话框，并做互斥保护。
///
/// 背景：Windows 上 `file_picker` 通过 FFI 直接在当前进程内调用 Shell 的
/// IFileOpenDialog（comdlg32.dll）。原生文件对话框**不允许并发打开**，
/// 重复调用会导致 Shell 侧访问冲突（0xC0000005），进程直接退出，且 Dart
/// 层无法捕获。因此在对话框显示期间拒绝新的选择请求，避免这类原生崩溃。
class DirectoryPickerService {
  DirectoryPickerService._();

  /// 是否已有原生目录选择对话框正在显示
  static bool _isPicking = false;

  /// 当前是否有目录选择对话框正在显示
  static bool get isPicking => _isPicking;

  /// 打开原生目录选择对话框。
  ///
  /// - 返回选中目录的路径；
  /// - 用户取消，或已有对话框正在显示（重复请求）时返回 null；
  /// - 原生对话框抛出异常时返回 null（不向上冒泡，避免中断调用方流程）。
  static Future<String?> pickDirectory({String? dialogTitle}) async {
    if (_isPicking) {
      debugPrint('[DirectoryPickerService] 已有目录选择对话框正在显示，忽略重复请求');
      return null;
    }
    _isPicking = true;
    try {
      return await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle,
      );
    } catch (e) {
      debugPrint('[DirectoryPickerService] 目录选择失败: $e');
      return null;
    } finally {
      _isPicking = false;
    }
  }
}
