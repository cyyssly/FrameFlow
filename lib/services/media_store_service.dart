import 'dart:io';
import 'package:flutter/services.dart';

class AlbumInfo {
  final String path;
  final String name;
  final int imageCount;

  AlbumInfo({required this.path, required this.name, required this.imageCount});
}

class MediaStoreService {
  static const _channel = MethodChannel('com.example.slide_show/media_store');

  /// 查询设备上所有包含图片的相册（Android 专用）
  static Future<List<AlbumInfo>> getImageAlbums() async {
    if (!Platform.isAndroid) return [];

    try {
      final result = await _channel.invokeMethod('getImageAlbums');
      if (result == null) return [];

      final List<dynamic> albums = result as List<dynamic>;
      return albums.map((album) {
        final map = album as Map<String, dynamic>;
        return AlbumInfo(
          path: map['path'] as String,
          name: map['name'] as String,
          imageCount: map['imageCount'] as int,
        );
      }).toList();
    } catch (e) {
      // 如果 MethodChannel 不可用，回退到系统目录扫描
      return _fallbackScan();
    }
  }

  /// 请求存储读取权限（Android 专用）
  /// 返回 true 表示已授权
  static Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod('requestStoragePermission');
      return result == true;
    } catch (_) {
      return true; // 非 Android 或调试模式默认通过
    }
  }

  /// 通过原生端读取图片字节数据（绕过 Scoped Storage 限制）
  static Future<Uint8List?> readImageBytes(String path) async {
    if (!Platform.isAndroid) {
      try {
        return await File(path).readAsBytes();
      } catch (_) {
        return null;
      }
    }
    try {
      final result = await _channel.invokeMethod('readImageBytes', {
        'path': path,
      });
      if (result == null) return null;
      return (result as Uint8List);
    } catch (_) {
      // 回退到直接文件读取
      try {
        return await File(path).readAsBytes();
      } catch (_) {
        return null;
      }
    }
  }

  /// 回退方案：扫描常见图片目录
  static Future<List<AlbumInfo>> _fallbackScan() async {
    if (!Platform.isAndroid) return [];

    const commonDirs = [
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Pictures/Screenshots',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Images',
      '/storage/emulated/0/Telegram/Telegram Images',
      '/storage/emulated/0/WeiXin',
      '/storage/emulated/0/tencent/MicroMsg/WeiXin',
    ];

    const supportedExtensions = {
      'jpg',
      'jpeg',
      'png',
      'webp',
      'bmp',
      'gif',
      'tiff',
      'tif',
    };

    final albums = <AlbumInfo>[];

    for (final dirPath in commonDirs) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;

      try {
        int count = 0;
        await for (final entity in dir.list(recursive: false)) {
          if (entity is File) {
            final ext = entity.path.split('.').last.toLowerCase();
            if (supportedExtensions.contains(ext)) {
              count++;
            }
          }
        }
        if (count > 0) {
          albums.add(
            AlbumInfo(
              path: dirPath,
              name: dirPath.split('/').last,
              imageCount: count,
            ),
          );
        }
      } catch (_) {
        // 跳过无权限的目录
      }
    }

    // 按图片数量降序排列
    albums.sort((a, b) => b.imageCount.compareTo(a.imageCount));
    return albums;
  }
}
