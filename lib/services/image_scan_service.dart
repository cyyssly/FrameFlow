import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/services/media_store_service.dart';

/// 图片扫描与元数据读取服务
class ImageScanService {
  static const supportedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
    'tiff',
    'tif',
  };

  /// 扫描文件夹中的图片（Android 走 MediaStore，桌面走文件系统）
  static Future<List<ImageItem>> scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) async {
    // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
    if (Platform.isAndroid) {
      final images = await MediaStoreService.getFolderImages(folderPath);
      return images
          .where((item) => _isSupportedImage(item.path))
          .map((item) => ImageItem(name: item.name, path: item.path))
          .toList();
    }

    // 桌面端使用文件系统 API
    List<File> files = [];
    final dir = Directory(folderPath);
    if (settings.recursiveScan) {
      await for (var entity in dir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }
    } else {
      final entities = await dir.list().toList();
      files = entities.whereType<File>().toList();
    }

    return files
        .where((file) => _isSupportedImage(file.path))
        .map(
          (file) => ImageItem(
            name: file.path.split(Platform.pathSeparator).last,
            path: file.path,
          ),
        )
        .toList();
  }

  /// 判断是否为支持的图片格式
  static bool _isSupportedImage(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex == -1) return false;
    final ext = path.toLowerCase().substring(dotIndex + 1);
    return supportedExtensions.contains(ext);
  }

  /// 读取图片宽高比（宽/高），失败返回 null
  /// 读取整个文件（保证尺寸信息完整），在后台 isolate 中解析，不阻塞 UI
  static Future<double?> readAspectRatio(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      // 在后台 isolate 中解析，避免阻塞 UI 线程
      return await compute(_parseAspectRatio, bytes);
    } catch (_) {}
    return null;
  }

  /// 在后台 isolate 中执行的解析函数
  static double? _parseAspectRatio(Uint8List bytes) {
    try {
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info != null && info.height > 0) {
        return info.width / info.height;
      }
    } catch (_) {}
    return null;
  }

  /// 批量读取宽高比
  /// 先并行读取所有文件字节（IO 异步不阻塞 UI），再在单个后台 isolate 中
  /// 串行解析所有宽高比（避免创建多个 isolate 的开销）
  /// 返回与 [paths] 对应的宽高比列表
  static Future<List<double?>> readAspectRatios(List<String> paths) async {
    // 并行读取所有文件字节
    final bytesList = await Future.wait(
      paths.map((p) async {
        try {
          return await File(p).readAsBytes();
        } catch (_) {
          return null;
        }
      }),
    );
    // 在单个 isolate 中串行解析
    return await compute(_parseAspectRatios, bytesList);
  }

  /// 在后台 isolate 中批量解析宽高比
  static List<double?> _parseAspectRatios(List<Uint8List?> bytesList) {
    final results = List<double?>.filled(bytesList.length, null);
    for (var i = 0; i < bytesList.length; i++) {
      final bytes = bytesList[i];
      if (bytes == null) continue;
      try {
        final decoder = img.findDecoderForData(bytes);
        final info = decoder?.startDecode(bytes);
        if (info != null && info.height > 0) {
          results[i] = info.width / info.height;
        }
      } catch (_) {}
    }
    return results;
  }
}
