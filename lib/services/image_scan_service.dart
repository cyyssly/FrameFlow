import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/services/image_formats.dart';
import 'package:frame_flow/services/media_store_service.dart';

/// 图片扫描与元数据读取服务
class ImageScanService {
  /// 扫描文件夹中的图片（Android 走 MediaStore，桌面走文件系统）
  ///
  /// 扫描结果会剔除 [SettingsProvider.excludedPaths] 中记录的图片：
  /// 排除操作只是把路径记进设置，若不在扫描时过滤，退出页面重新进入后
  /// 被排除的图片会再次出现。
  static Future<List<ImageItem>> scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) async {
    // Windows 文件路径不区分大小写，统一转小写比较，避免因大小写差异漏过滤
    final excluded = {
      for (final path in settings.excludedPaths)
        Platform.isWindows ? path.toLowerCase() : path,
    };
    bool notExcluded(ImageItem item) => !excluded.contains(
      Platform.isWindows ? item.path.toLowerCase() : item.path,
    );

    // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
    if (Platform.isAndroid) {
      // MediaStore 已索引好宽高，直接透传，调用方无需再读原图
      final images = await MediaStoreService.getFolderImages(folderPath);
      return images
          .where((item) => isSupportedImagePath(item.path) && notExcluded(item))
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

    final items = <ImageItem>[];
    for (final file in files) {
      if (!isSupportedImagePath(file.path)) continue;
      // 文件大小与修改时间在此读入，避免瀑布流卡片在 build 里同步读盘
      DateTime? modifiedAt;
      int? size;
      try {
        final stat = await file.stat();
        modifiedAt = stat.modified;
        size = stat.size;
      } catch (_) {
        // 文件被占用/权限不足时忽略，对应信息显示为「未知」
      }
      items.add(
        ImageItem(
          name: file.path.split(Platform.pathSeparator).last,
          path: file.path,
          modifiedAt: modifiedAt,
          size: size,
        ),
      );
    }

    return items.where(notExcluded).toList();
  }

  /// 解析宽高比时最多读取的文件头字节数。
  ///
  /// JPEG 的尺寸在 SOF 段、PNG 在 IHDR、WebP 在 VP8X/VP8L 头，
  /// 都位于文件很靠前的位置；256KB 足以覆盖体积较大的 EXIF/ICC 头。
  static const int _headerReadLimit = 256 * 1024;

  /// 头部解析失败时的回退上限。
  ///
  /// 少数图片的尺寸信息不在文件头附近，无法只靠文件头解析；
  /// 仅在其体积不超过该上限时才退回整文件读取，
  /// 避免为个别文件付出读取几十 MB 的代价。
  static const int _wholeFileFallbackLimit = 8 * 1024 * 1024;

  /// 批量读取宽高比（宽/高），无法解析的项为 null。
  ///
  /// 关键点：**读取文件这一步也在后台 isolate 里执行**。
  /// 若先在主 isolate 读完全部字节再交给 [compute]，isolate 之间会
  /// 完整拷贝一次数据——手机上一批 30 张原图会产生上百 MB 的无谓拷贝，
  /// 这正是移动端加载明显慢于桌面的主要原因之一。
  static Future<List<double?>> readAspectRatios(List<String> paths) async {
    if (paths.isEmpty) return const [];
    // 单 isolate 串行读取文件头，图片多时耗时较长。
    // 拆成多个小块并行处理，显著缩短共享目录分页接口的响应时间。
    const chunkSize = 150;
    if (paths.length <= chunkSize) {
      return await compute(_parseAspectRatiosFromPaths, paths);
    }
    final chunks = <List<String>>[];
    for (var i = 0; i < paths.length; i += chunkSize) {
      final end = i + chunkSize < paths.length ? i + chunkSize : paths.length;
      chunks.add(paths.sublist(i, end));
    }
    final results = await Future.wait(
      chunks.map((chunk) => compute(_parseAspectRatiosFromPaths, chunk)),
    );
    return [for (final chunk in results) ...chunk];
  }

  /// 后台 isolate 入口：逐张只读文件头并解析宽高比。
  ///
  /// 在单个 isolate 中串行处理，避免为每张图创建 isolate 的开销。
  static List<double?> _parseAspectRatiosFromPaths(List<String> paths) {
    final results = List<double?>.filled(paths.length, null);
    for (var i = 0; i < paths.length; i++) {
      results[i] = _readAspectRatioSync(paths[i]);
    }
    return results;
  }

  /// 同步读取文件头并解析宽高比（仅可在后台 isolate 中调用）。
  static double? _readAspectRatioSync(String path) {
    try {
      final file = File(path);
      final fileLength = file.lengthSync();
      if (fileLength <= 0) return null;

      final readLength = fileLength < _headerReadLimit
          ? fileLength
          : _headerReadLimit;

      var ratio = _tryParseRatio(file, readLength);

      // 头部不足以解析（尺寸信息不在文件头附近）时，对中小文件整读一次
      if (ratio == null && fileLength > readLength) {
        if (fileLength <= _wholeFileFallbackLimit) {
          ratio = _tryParseRatio(file, fileLength);
        }
      }
      return ratio;
    } catch (_) {
      return null;
    }
  }

  /// 读取 [length] 字节并尝试解析宽高比，失败返回 null。
  static double? _tryParseRatio(File file, int length) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final bytes = handle.readSync(length);

      // PNG 先直接读 IHDR：image 包的 PngDecoder.startDecode 会一直扫描到
      // IEND 才返回，只传文件头时体积较大的 PNG 会被判为数据不完整而返回
      // null（瀑布流随即按正方形排版，表现为宽高比错误）。
      final headerRatio = _readPngRatio(bytes);
      if (headerRatio != null) return headerRatio;

      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info != null && info.height > 0) {
        return info.width / info.height;
      }
    } catch (_) {
    } finally {
      // 无论成功与否都要关闭句柄，避免文件描述符泄漏
      try {
        handle?.closeSync();
      } catch (_) {}
    }
    return null;
  }

  /// 直接从 PNG 的 IHDR 块读取宽高比。
  ///
  /// IHDR 固定为 PNG 的第一个块，宽高位于文件偏移 16~23 字节（大端），
  /// 因此只需读取文件开头即可，无需读完整张图片。
  static double? _readPngRatio(List<int> bytes) {
    if (bytes.length < 24) return null;
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return null;
    }
    // 第一个块类型必须是 "IHDR"
    if (bytes[12] != 0x49 ||
        bytes[13] != 0x48 ||
        bytes[14] != 0x44 ||
        bytes[15] != 0x52) {
      return null;
    }
    final width =
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final height =
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    if (width <= 0 || height <= 0) return null;
    return width / height;
  }
}
