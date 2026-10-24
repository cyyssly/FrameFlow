import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/models/lan_models.dart';
import 'package:frame_flow/services/lan_protocol.dart';

/// 局域网客户端：负责向远端主机发起只读的 HTTP 请求。
class LanClientService {
  static final LanClientService instance = LanClientService._();

  LanClientService._();

  static const Duration _timeout = Duration(seconds: 4);

  /// 文件列表类接口的响应时间上限。
  ///
  /// 共享目录文件较多时，服务端需要遍历目录并读取图片宽高，
  /// 首次请求可能明显超过心跳接口的 4 秒，不能沿用同一个超时时间。
  static const Duration _dataTimeout = Duration(seconds: 30);

  HttpClient? _client;

  HttpClient get _http =>
      _client ??= HttpClient()..connectionTimeout = _timeout;

  /// 读取远端设备信息，设备不可达时返回 null
  Future<Map<String, dynamic>?> fetchInfo(LanDevice device) async {
    final uri = Uri.parse('${device.baseUrl}${LanProtocol.infoPath}');
    return _getJson(uri);
  }

  /// 下载二进制资源（如缩略图），失败返回 null
  Future<Uint8List?> fetchBytes(String url) async {
    try {
      final request = await _http.getUrl(Uri.parse(url)).timeout(_dataTimeout);
      final response = await request.close().timeout(_dataTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add).timeout(_dataTimeout);
      return builder.takeBytes();
    } catch (_) {
      return null;
    }
  }

  /// 请求远端设备把某张图片加入排除列表（仅排除播放，不删除文件）
  ///
  /// 远端未开启“允许远程排除播放”或校验失败时返回 false。
  Future<bool> excludeImage(
    LanDevice device, {
    required String folderId,
    required String id,
  }) async {
    final uri = _api(device, LanProtocol.excludePath, {
      'folder': folderId,
      'id': id,
    });
    try {
      final request = await _http.postUrl(uri).timeout(_dataTimeout);
      request.contentLength = 0;
      final response = await request.close().timeout(_dataTimeout);
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  /// 读取远端共享的文件夹列表
  Future<List<RemoteFolder>?> fetchFolders(LanDevice device) async {
    final uri = Uri.parse('${device.baseUrl}${LanProtocol.foldersPath}');
    final data = await _getJson(uri, timeout: _dataTimeout);
    final raw = data?['folders'];
    if (raw is! List) return null;

    final folders = <RemoteFolder>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty) continue;
      final name = (entry['name'] as String?)?.trim();
      folders.add(
        RemoteFolder(
          id: id,
          name: name != null && name.isNotEmpty ? name : id,
          imageCount: entry['count'] is int ? entry['count'] as int : 0,
        ),
      );
    }
    return folders;
  }

  /// 读取远端文件夹中的一页图片
  ///
  /// [sort] 为 `name` / `time` / `size` / `random`，为空时使用服务端默认顺序；
  /// [order] 为 `asc` / `desc`；随机排序需同时传入同一次浏览固定的 [seed]，
  /// 否则各页顺序会不一致。
  Future<RemoteImagePage?> fetchImages(
    LanDevice device, {
    required String folderId,
    int offset = 0,
    int limit = 60,
    String? sort,
    String? order,
    String? seed,
  }) async {
    final uri = _api(device, LanProtocol.imagesPath, {
      'folder': folderId,
      'offset': '$offset',
      'limit': '$limit',
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
      if (seed != null && seed.isNotEmpty) 'seed': seed,
    });
    final data = await _getJson(uri, timeout: _dataTimeout);
    final raw = data?['items'];
    if (raw is! List) return null;

    final items = <ImageItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty) continue;
      final aspect = entry['aspect'];
      final mtime = entry['mtime'];
      items.add(
        ImageItem(
          name: (entry['name'] as String?)?.trim().isNotEmpty == true
              ? entry['name'] as String
              : id.split('/').last,
          path: '',
          aspectRatio: aspect is num ? aspect.toDouble() : null,
          source: ImageSource.remote,
          remoteUrl: imageUrl(device, folderId, id),
          thumbUrl: thumbUrl(device, folderId, id),
          deviceId: device.id,
          // 同一设备的不同共享目录可能包含同名相对路径，
          // 带上文件夹标识才能保证播放列表去重正确
          remoteId: '$folderId/$id',
          modifiedAt: mtime is int
              ? DateTime.fromMillisecondsSinceEpoch(mtime)
              : null,
          size: entry['size'] is int ? entry['size'] as int : null,
        ),
      );
    }

    final total = data?['total'] is int ? data!['total'] as int : items.length;
    return RemoteImagePage(
      items: items,
      total: total,
      nextOffset: offset + items.length,
    );
  }

  /// 取回远端文件夹的全部图片元数据，失败时返回 null
  Future<List<ImageItem>?> fetchAllImages(
    LanDevice device, {
    required String folderId,
    int pageSize = 500,
  }) async {
    final all = <ImageItem>[];
    var offset = 0;
    while (true) {
      final page = await fetchImages(
        device,
        folderId: folderId,
        offset: offset,
        limit: pageSize,
      );
      if (page == null) return null;
      all.addAll(page.items);
      if (page.items.isEmpty || all.length >= page.total) break;
      if (page.nextOffset <= offset) break;
      offset = page.nextOffset;
    }
    return all;
  }

  /// 远端原图地址
  String imageUrl(LanDevice device, String folderId, String id) {
    return _api(device, LanProtocol.imagePath, {
      'folder': folderId,
      'id': id,
    }).toString();
  }

  /// 远端缩略图地址
  String thumbUrl(
    LanDevice device,
    String folderId,
    String id, {
    int width = 800,
  }) {
    return _api(device, LanProtocol.thumbPath, {
      'folder': folderId,
      'id': id,
      'w': '$width',
    }).toString();
  }

  Uri _api(LanDevice device, String path, Map<String, String> query) {
    return Uri.parse('${device.baseUrl}$path').replace(queryParameters: query);
  }

  Future<Map<String, dynamic>?> _getJson(
    Uri uri, {
    Duration timeout = _timeout,
  }) async {
    try {
      final request = await _http.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
