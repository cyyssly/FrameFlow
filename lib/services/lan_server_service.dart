import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/services/image_scan_service.dart';
import 'package:frame_flow/services/lan_protocol.dart';
import 'package:frame_flow/services/media_store_service.dart';

/// 缩略图生成任务（可在后台 isolate 执行）
class _ThumbTask {
  final Uint8List bytes;
  final int width;

  const _ThumbTask(this.bytes, this.width);
}

/// 顶层函数才能作为 [compute] 的入口
Uint8List? _createThumbnail(_ThumbTask task) {
  try {
    final decoded = img.decodeImage(task.bytes);
    if (decoded == null) return null;
    final resized = decoded.width <= task.width
        ? decoded
        : img.copyResize(
            decoded,
            width: task.width,
            interpolation: img.Interpolation.average,
          );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  } catch (_) {
    return null;
  }
}

class _FolderCache {
  final List<ImageItem> images;
  final DateTime timestamp;

  const _FolderCache(this.images, this.timestamp);
}

/// 排序后的图片列表缓存（按排序参数区分）
///
/// 按时间/大小排序需要先读取全部文件的 stat，代价较高；
/// 同一排序参数下的连续分页请求直接复用结果。
class _SortedCache {
  final List<ImageItem> images;
  final Map<String, FileStat> stats;
  final DateTime timestamp;

  const _SortedCache(this.images, this.stats, this.timestamp);
}

/// 局域网 HTTP 图片服务。
///
/// 只读：仅提供共享文件夹内的图片元数据、缩略图与原图，
/// 不提供任何删除 / 修改接口。
class LanServerService {
  static final LanServerService instance = LanServerService._();

  LanServerService._();

  /// 文件夹扫描结果缓存时长。
  ///
  /// 分页拉取大目录时总耗时可能超过旧值（10 秒），过期后每页都会重新扫描，
  /// 进一步放大响应时间；这里放宽到 1 分钟，兼顾新鲜度与分页性能。
  static const Duration _scanCacheDuration = Duration(seconds: 60);

  HttpServer? _server;
  int _port = LanProtocol.defaultHttpPort;
  String _deviceId = '';
  String _deviceName = 'FrameFlow';
  List<String> Function()? _folderPaths;
  bool Function()? _recursiveScan;
  final Map<String, _FolderCache> _folderCache = {};

  /// 排序结果缓存，键为「目录|排序方式|方向|随机种子」
  final Map<String, _SortedCache> _sortCache = {};

  /// 已读取过的图片宽高比缓存，避免分页时重复读取同一批文件头
  final Map<String, double?> _aspectCache = {};

  bool get isRunning => _server != null;

  int get port => _server?.port ?? _port;

  Future<void> start({
    required String deviceId,
    required String deviceName,
    required List<String> Function() folderPaths,
    required bool Function() recursiveScan,
  }) async {
    _deviceId = deviceId;
    _deviceName = deviceName;
    _folderPaths = folderPaths;
    _recursiveScan = recursiveScan;

    if (_server != null) return;

    HttpServer? server;
    var candidate = LanProtocol.defaultHttpPort;
    for (var i = 0; i < 8 && server == null; i++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, candidate);
      } on SocketException {
        candidate++;
      }
    }
    if (server == null) {
      throw const SocketException('LAN server port unavailable');
    }

    _server = server;
    _port = server.port;
    server.listen(_handleRequest, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _folderCache.clear();
    _aspectCache.clear();
    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      final uri = request.uri;
      switch (uri.path) {
        case LanProtocol.infoPath:
          await _writeJson(response, _info());
          return;
        case LanProtocol.foldersPath:
          await _writeJson(response, {'folders': await _foldersJson()});
          return;
        case LanProtocol.imagesPath:
          await _serveImages(uri, response);
          return;
        case LanProtocol.imagePath:
          await _serveOriginal(request, uri, response);
          return;
        case LanProtocol.thumbPath:
          await _serveThumb(uri, response);
          return;
        default:
          response.statusCode = HttpStatus.notFound;
          response.write('Not Found');
          await response.close();
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.write('Server Error');
        await response.close();
      } catch (_) {
        // 连接已被对端关闭，忽略
      }
    }
  }

  Map<String, Object?> _info() {
    return {
      'v': LanProtocol.version,
      'id': _deviceId,
      'name': _deviceName,
      'port': _port,
      'folders': _folderPaths?.call().length ?? 0,
      'platform': Platform.operatingSystem,
    };
  }

  Future<List<Map<String, Object?>>> _foldersJson() async {
    final paths = _folderPaths?.call() ?? const <String>[];
    final result = <Map<String, Object?>>[];
    for (final path in paths) {
      final images = await _imagesForPath(path);
      result.add({
        'id': folderIdFor(path),
        'name': _folderName(path),
        'count': images.length,
      });
    }
    return result;
  }

  Future<List<ImageItem>> _imagesForPath(String folder) async {
    final cached = _folderCache[folder];
    if (cached != null &&
        DateTime.now().difference(cached.timestamp) < _scanCacheDuration) {
      return cached.images;
    }
    final images = await _scanFolder(folder);
    // 目录内容变化后，旧的排序结果不再有效
    _sortCache.removeWhere((key, _) => key.startsWith('$folder|'));
    _folderCache[folder] = _FolderCache(images, DateTime.now());
    return images;
  }

  Future<List<ImageItem>> _scanFolder(String folder) async {
    // Android 走 MediaStore，既绕过 Scoped Storage，也能复用其已索引的宽高
    if (Platform.isAndroid) {
      final items = await MediaStoreService.getFolderImages(folder);
      final result =
          items.where((item) => _isSupportedImage(item.path)).toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      return result;
    }

    final dir = Directory(folder);
    if (!await dir.exists()) return const [];

    final recursive = _recursiveScan?.call() ?? true;
    final files = <File>[];
    await for (final entity in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is File && _isSupportedImage(entity.path)) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files
        .map(
          (file) => ImageItem(
            name: file.path.split(Platform.pathSeparator).last,
            path: file.path,
          ),
        )
        .toList();
  }

  /// 按查询参数返回排好序的图片列表。
  ///
  /// 支持 `sort=name|time|size|random` 与 `order=asc|desc`；
  /// 不传 `sort` 时保持目录扫描的默认顺序，兼容旧客户端。
  /// 随机排序用 `seed` 保证同一次浏览的各页顺序一致。
  Future<_SortedCache> _imagesForServe(
    String root, {
    String? sort,
    required String order,
    required String seed,
  }) async {
    final images = await _imagesForPath(root);
    if (sort == null || sort.isEmpty) {
      return _SortedCache(images, const {}, DateTime.now());
    }

    final key = '$root|$sort|$order|$seed';
    final cached = _sortCache[key];
    if (cached != null) {
      if (DateTime.now().difference(cached.timestamp) < _scanCacheDuration) {
        return cached;
      }
      _sortCache.remove(key);
    }

    final descending = order == 'desc';
    final stats = <String, FileStat>{};
    List<ImageItem> sorted;

    if (sort == 'random') {
      sorted = [...images]
        ..sort(
          (a, b) =>
              _hash('$seed:${a.path}').compareTo(_hash('$seed:${b.path}')),
        );
    } else if (sort == 'name') {
      sorted = [...images]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (descending) sorted = sorted.reversed.toList();
    } else {
      // 时间 / 大小排序需要全量 stat；结果随排序缓存一起复用
      final entries = await Future.wait(
        images.map((item) async {
          try {
            final stat = await File(item.path).stat();
            if (stat.type != FileSystemEntityType.notFound) {
              return MapEntry<ImageItem, FileStat?>(item, stat);
            }
          } catch (_) {
            // 读取失败按 0 处理，保证排序稳定
          }
          return MapEntry<ImageItem, FileStat?>(item, null);
        }),
      );
      for (final entry in entries) {
        final stat = entry.value;
        if (stat != null) stats[entry.key.path] = stat;
      }
      int sizeOf(ImageItem item) => stats[item.path]?.size ?? 0;
      int timeOf(ImageItem item) =>
          stats[item.path]?.modified.millisecondsSinceEpoch ?? 0;
      sorted = [...images]
        ..sort(
          sort == 'size'
              ? (a, b) => sizeOf(a).compareTo(sizeOf(b))
              : (a, b) => timeOf(a).compareTo(timeOf(b)),
        );
      if (descending) sorted = sorted.reversed.toList();
    }

    final result = _SortedCache(sorted, stats, DateTime.now());
    // 避免用户反复点“随机”导致缓存无限增长
    if (_sortCache.length > 24) {
      _sortCache.remove(_sortCache.keys.first);
    }
    _sortCache[key] = result;
    return result;
  }

  Future<void> _serveImages(Uri uri, HttpResponse response) async {
    final root = _folderById(uri.queryParameters['folder']);
    if (root == null) {
      response.statusCode = HttpStatus.notFound;
      response.write('Folder Not Found');
      await response.close();
      return;
    }

    final offset = (int.tryParse(uri.queryParameters['offset'] ?? '') ?? 0)
        .clamp(0, 1 << 30);
    final limit = (int.tryParse(uri.queryParameters['limit'] ?? '') ?? 200)
        .clamp(1, 500);

    final serve = await _imagesForServe(
      root,
      sort: uri.queryParameters['sort'],
      order: uri.queryParameters['order'] == 'desc' ? 'desc' : 'asc',
      seed: uri.queryParameters['seed'] ?? '',
    );
    final images = serve.images;
    final page = images.skip(offset).take(limit).toList();
    // 桌面端图片没有预存宽高比，只解析这一页中缺失且尚未缓存的文件头
    final pendingPaths = <String>[];
    final pendingIndexes = <int>[];
    final ratioByPageIndex = <int, double?>{};
    for (var i = 0; i < page.length; i++) {
      final item = page[i];
      if (item.aspectRatio != null) {
        ratioByPageIndex[i] = item.aspectRatio;
      } else if (_aspectCache.containsKey(item.path)) {
        ratioByPageIndex[i] = _aspectCache[item.path];
      } else {
        pendingPaths.add(item.path);
        pendingIndexes.add(i);
      }
    }
    if (pendingPaths.isNotEmpty) {
      final ratios = await ImageScanService.readAspectRatios(pendingPaths);
      for (var i = 0; i < pendingIndexes.length; i++) {
        ratioByPageIndex[pendingIndexes[i]] = ratios[i];
        _aspectCache[pendingPaths[i]] = ratios[i];
      }
    }

    // 并行读取文件元数据：逐个 await 在一页数百张图时会明显拖慢响应，
    // 目录较大时容易让客户端超时。
    // 按时间/大小排序时已为全量文件取过 stat，直接复用。
    final stats = serve.stats.isNotEmpty
        ? page.map((item) => serve.stats[item.path]).toList()
        : await Future.wait(
            page.map((item) async {
              try {
                final stat = await File(item.path).stat();
                if (stat.type != FileSystemEntityType.notFound) return stat;
              } catch (_) {
                // Android Scoped Storage 下 stat 可能失败，元数据留空
              }
              return null;
            }),
          );

    final itemsJson = <Map<String, Object?>>[];
    for (var i = 0; i < page.length; i++) {
      final item = page[i];
      final stat = stats[i];
      itemsJson.add({
        'id': _relativeTo(root, item.path),
        'name': item.name,
        'size': stat?.size,
        'mtime': stat?.modified.millisecondsSinceEpoch,
        'aspect': item.aspectRatio ?? ratioByPageIndex[i],
      });
    }

    await _writeJson(response, {
      'total': images.length,
      'offset': offset,
      'items': itemsJson,
    });
  }

  Future<void> _serveOriginal(
    HttpRequest request,
    Uri uri,
    HttpResponse response,
  ) async {
    final root = _folderById(uri.queryParameters['folder']);
    if (root == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final fullPath = _resolveWithin(root, uri.queryParameters['id'] ?? '');
    if (fullPath == null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    // Android 的图片可能不在应用可直读的路径上，统一走原生通道
    if (Platform.isAndroid) {
      final bytes = await MediaStoreService.readImageBytes(fullPath);
      if (bytes == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      response.headers.contentType = _contentType(fullPath);
      response.headers.set(
        HttpHeaders.cacheControlHeader,
        'public, max-age=86400',
      );
      response.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
      return;
    }

    final file = File(fullPath);
    FileStat stat;
    try {
      stat = await file.stat();
    } catch (_) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (stat.type == FileSystemEntityType.notFound) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final etag = '"${stat.modified.millisecondsSinceEpoch}-${stat.size}"';
    response.headers.set(HttpHeaders.etagHeader, etag);
    if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }

    response.headers.contentType = _contentType(fullPath);
    response.headers.set(
      HttpHeaders.cacheControlHeader,
      'public, max-age=86400',
    );
    response.contentLength = stat.size;
    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _serveThumb(Uri uri, HttpResponse response) async {
    final root = _folderById(uri.queryParameters['folder']);
    if (root == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final fullPath = _resolveWithin(root, uri.queryParameters['id'] ?? '');
    if (fullPath == null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    final width = (int.tryParse(uri.queryParameters['w'] ?? '') ?? 400).clamp(
      64,
      1024,
    );

    Uint8List? source;
    var mtime = 0;
    if (Platform.isAndroid) {
      source = await MediaStoreService.readImageBytes(fullPath);
    } else {
      try {
        final file = File(fullPath);
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.notFound) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        mtime = stat.modified.millisecondsSinceEpoch;
        source = await file.readAsBytes();
      } catch (_) {
        source = null;
      }
    }
    if (source == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final cacheFile = File(
      '${_thumbDir().path}${Platform.pathSeparator}'
      '${_hash('$fullPath|$mtime|$width')}.jpg',
    );
    Uint8List? thumb;
    if (await cacheFile.exists()) {
      try {
        thumb = await cacheFile.readAsBytes();
      } catch (_) {
        thumb = null;
      }
    }
    if (thumb == null || thumb.isEmpty) {
      thumb = await compute(_createThumbnail, _ThumbTask(source, width));
      if (thumb == null) {
        response.statusCode = HttpStatus.unsupportedMediaType;
        await response.close();
        return;
      }
      try {
        await cacheFile.writeAsBytes(thumb, flush: false);
      } catch (_) {
        // 缓存写入失败不影响本次响应
      }
    }

    response.headers.contentType = ContentType('image', 'jpeg');
    response.headers.set(
      HttpHeaders.cacheControlHeader,
      'public, max-age=86400',
    );
    response.contentLength = thumb.length;
    response.add(thumb);
    await response.close();
  }

  Future<void> _writeJson(HttpResponse response, Object data) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    await response.close();
  }

  /// 根据稳定标识查找共享目录
  String? _folderById(String? id) {
    if (id == null || id.isEmpty) return null;
    final paths = _folderPaths?.call() ?? const <String>[];
    for (final path in paths) {
      if (folderIdFor(path) == id) return path;
    }
    return null;
  }

  /// 为共享目录生成稳定标识。
  ///
  /// 不能直接使用列表下标：用户增删共享文件夹后位置会变化，
  /// 已持久化在其他设备上的选择会因此指向错误目录。
  static String folderIdFor(String path) {
    final normalized = path.replaceAll('\\', '/');
    return '${_hash('folder:$normalized')}${_hash('folder2:$normalized')}';
  }

  static bool _isSupportedImage(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1) return false;
    final ext = path.substring(dot + 1).toLowerCase();
    return ImageScanService.supportedExtensions.contains(ext);
  }

  static String _folderName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }

  /// 把远端传入的相对路径解析到共享目录内，越界时返回 null
  static String? _resolveWithin(String root, String relative) {
    if (relative.isEmpty) return null;
    final normalizedRoot = root.replaceAll('\\', '/');
    final stack = <String>[];
    for (final part in relative.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (stack.isEmpty) return null;
        stack.removeLast();
      } else {
        stack.add(part);
      }
    }
    if (stack.isEmpty) return null;
    final joined = '$normalizedRoot/${stack.join('/')}';
    if (!joined.startsWith('$normalizedRoot/')) return null;
    return joined;
  }

  /// 计算文件相对共享目录的路径，统一使用 '/' 分隔
  static String _relativeTo(String root, String path) {
    final normalizedRoot = root.replaceAll('\\', '/');
    final normalizedPath = path.replaceAll('\\', '/');
    if (normalizedPath == normalizedRoot) return '';
    if (normalizedPath.startsWith('$normalizedRoot/')) {
      return normalizedPath.substring(normalizedRoot.length + 1);
    }
    return normalizedPath.split('/').last;
  }

  static ContentType _contentType(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot == -1 ? '' : path.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return ContentType('image', 'jpeg');
      case 'png':
        return ContentType('image', 'png');
      case 'webp':
        return ContentType('image', 'webp');
      case 'gif':
        return ContentType('image', 'gif');
      case 'bmp':
        return ContentType('image', 'bmp');
      case 'tif':
      case 'tiff':
        return ContentType('image', 'tiff');
      default:
        return ContentType('application', 'octet-stream');
    }
  }

  Directory _thumbDir() {
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}frame_flow_lan_thumbs',
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// FNV-1a 哈希，用于生成稳定的缩略图缓存文件名
  static String _hash(String input) {
    var hash = 0x811c9dc5;
    for (final code in input.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
