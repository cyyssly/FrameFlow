import 'dart:io';

import 'package:flutter/painting.dart';

/// 本地图片的 [FileImage] 变体：把文件修改时间与大小纳入缓存键。
///
/// `FileImage` 只用文件路径作为缓存键，同名文件内容被替换后（例如应用收起到
/// 系统托盘期间在资源管理器里用同名文件覆盖了图片）仍会命中旧的解码结果。
/// 加入修改时间与大小后，文件一变就会重新读盘解码，文件未变时照常复用缓存。
class LocalFileImage extends FileImage {
  LocalFileImage(super.file) : stamp = _stampOf(file);

  /// 文件修改时间 + 大小；读取失败时为空串（退回纯路径缓存，与 FileImage 一致）
  final String stamp;

  static String _stampOf(File file) {
    try {
      final stat = file.statSync();
      return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return '';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LocalFileImage &&
      other.file.path == file.path &&
      other.scale == scale &&
      other.stamp == stamp;

  @override
  int get hashCode => Object.hash(file.path, scale, stamp);
}
