import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:frame_flow/services/lan_server_service.dart';
import 'package:frame_flow/services/lan_protocol.dart';

/// 远程排除接口：只有开启开关时才允许，且只能排除共享目录内的图片。
void main() {
  late Directory folder;
  late List<String> excluded;
  var allowExclude = true;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('ff_lan_exclude');
    for (final name in ['a.jpg', 'b.jpg']) {
      File(
        '${folder.path}${Platform.pathSeparator}$name',
      ).writeAsBytesSync(const [1, 2, 3]);
    }
    excluded = [];
    allowExclude = true;
  });

  tearDown(() async {
    await LanServerService.instance.stop();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  Future<void> startServer() {
    return LanServerService.instance.start(
      deviceId: 'test-device',
      deviceName: 'Test',
      folderPaths: () => [folder.path],
      recursiveScan: () => false,
      excludedPaths: () => excluded,
      remoteExcludeEnabled: () => allowExclude,
      remoteCopyEnabled: () => true,
      onExcludedPath: excluded.add,
    );
  }

  Future<HttpClientResponse> postExclude(String folderId, String id) async {
    final client = HttpClient();
    final uri = Uri.parse(
      'http://127.0.0.1:${LanServerService.instance.port}'
      '${LanProtocol.excludePath}',
    ).replace(queryParameters: {'folder': folderId, 'id': id});
    final request = await client.postUrl(uri);
    request.contentLength = 0;
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response;
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final client = HttpClient();
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${LanServerService.instance.port}$path'),
    )).close();
    final text = await response.transform(utf8.decoder).join();
    client.close();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  test('开启后排除成功并立即从列表中消失', () async {
    await startServer();
    final folderId = LanServerService.folderIdFor(folder.path);

    final info = await getJson(LanProtocol.infoPath);
    expect(info['rx'], isTrue);

    final response = await postExclude(folderId, 'a.jpg');
    expect(response.statusCode, HttpStatus.ok);
    expect(excluded.length, 1);
    expect(excluded.single.endsWith('a.jpg'), isTrue);

    final images = await getJson('${LanProtocol.imagesPath}?folder=$folderId');
    expect(images['total'], 1);
  });

  test('关闭开关时拒绝远程排除', () async {
    await startServer();
    allowExclude = false;

    final response = await postExclude(
      LanServerService.folderIdFor(folder.path),
      'a.jpg',
    );
    expect(response.statusCode, HttpStatus.forbidden);
    expect(excluded, isEmpty);
  });

  test('拒绝目录外的路径', () async {
    await startServer();

    final response = await postExclude(
      LanServerService.folderIdFor(folder.path),
      '../outside.jpg',
    );
    expect(response.statusCode, HttpStatus.notFound);
    expect(excluded, isEmpty);
  });
}
