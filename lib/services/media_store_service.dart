import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AlbumInfo {
  final String path;
  final String name;
  final int imageCount;
  final String? thumbnailPath;

  AlbumInfo({
    required this.path,
    required this.name,
    required this.imageCount,
    this.thumbnailPath,
  });
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
      debugPrint(
        '[MediaStoreService] getImageAlbums: received ${albums.length} albums from native',
      );
      return albums.map((album) {
        final map = Map<String, dynamic>.from(album as Map);
        debugPrint(
          '[MediaStoreService]   - ${map["name"]}: ${map["path"]} (${map["imageCount"]} images)',
        );
        return AlbumInfo(
          path: map['path'] as String,
          name: map['name'] as String,
          imageCount: map['imageCount'] as int,
          thumbnailPath: map['thumbnailPath'] as String?,
        );
      }).toList();
    } catch (e) {
      debugPrint(
        '[MediaStoreService] getImageAlbums failed, falling back to scan: $e',
      );
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

  /// 回退方案：扫描常见图片目录（含子目录）
  static Future<List<AlbumInfo>> _fallbackScan() async {
    if (!Platform.isAndroid) return [];

    const commonDirs = [
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/DCIM/Screenshots',
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Pictures/Screenshots',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Images',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Images/Sent',
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images',
      '/storage/emulated/0/Telegram/Telegram Images',
      '/storage/emulated/0/WeiXin',
      '/storage/emulated/0/tencent/MicroMsg/WeiXin',
      '/storage/emulated/0/Pictures/WeiXin',
      '/storage/emulated/0/DCIM/WeiXin',
      '/storage/emulated/0/Snapchat',
      '/storage/emulated/0/Instagram',
      '/storage/emulated/0/Facebook',
      '/storage/emulated/0/Twitter',
      '/storage/emulated/0/Reddit',
      '/storage/emulated/0/Bluetooth',
      '/storage/emulated/0/Ringtones',
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

    Future<({int count, String? firstImage})> scanDir(String dirPath) async {
      int count = 0;
      String? firstImage;
      final dir = Directory(dirPath);
      if (!await dir.exists()) return (count: 0, firstImage: null);
      try {
        await for (final entity in dir.list(recursive: false)) {
          if (entity is File) {
            final ext = entity.path.split('.').last.toLowerCase();
            if (supportedExtensions.contains(ext)) {
              count++;
              firstImage ??= entity.path;
            }
          }
        }
      } catch (_) {}
      return (count: count, firstImage: firstImage);
    }

    // 1. 直接扫描每个常见目录本身
    for (final dirPath in commonDirs) {
      final result = await scanDir(dirPath);
      if (result.count > 0) {
        albums.add(
          AlbumInfo(
            path: dirPath,
            name: dirPath.split('/').last,
            imageCount: result.count,
            thumbnailPath: result.firstImage,
          ),
        );
      }
    }

    // 2. 对 DCIM、Pictures、Download 等大目录，把每个子目录作为独立相册返回
    const parentDirs = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
    ];

    final seenPaths = albums.map((a) => a.path).toSet();

    for (final parentPath in parentDirs) {
      final parentDir = Directory(parentPath);
      if (!await parentDir.exists()) continue;

      try {
        await for (final subDir in parentDir.list(recursive: false)) {
          if (subDir is Directory) {
            final subResult = await scanDir(subDir.path);
            if (subResult.count > 0 && !seenPaths.contains(subDir.path)) {
              seenPaths.add(subDir.path);
              albums.add(
                AlbumInfo(
                  path: subDir.path,
                  name: subDir.path.split('/').last,
                  imageCount: subResult.count,
                  thumbnailPath: subResult.firstImage,
                ),
              );
            }
          }
        }
      } catch (_) {}
    }

    // 按图片数量降序排列
    albums.sort((a, b) => b.imageCount.compareTo(a.imageCount));
    return albums;
  }
}
