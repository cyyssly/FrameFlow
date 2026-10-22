import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:frame_flow/l10n/app_localizations.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/services/directory_picker_service.dart';
import 'package:frame_flow/services/lan_client_service.dart';
import 'package:frame_flow/services/media_store_service.dart';

/// 复用上次复制目录弹窗中的选择
enum _CopyDestinationChoice { cancel, change, useLast }

/// 远端图片复制到本机的公共流程，瀑布流页面与播放页共用。
class CopyService {
  CopyService._();

  /// 解析目标目录：优先询问是否沿用上次目录，未记录时直接弹出选择器。
  static Future<String?> resolveDestination(BuildContext context) async {
    final loc = AppLocalizations.of(context);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final last = settings.lastCopyDestination;
    if (last != null && last.isNotEmpty) {
      final choice = await showDialog<_CopyDestinationChoice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(loc.copyTo),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.lastCopyDestination,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              Text(
                displayDestination(last),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CopyDestinationChoice.cancel),
              child: Text(loc.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CopyDestinationChoice.change),
              child: Text(loc.changeDestination),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CopyDestinationChoice.useLast),
              child: Text(loc.startCopy),
            ),
          ],
        ),
      );
      if (!context.mounted) return null;
      if (choice == _CopyDestinationChoice.useLast) return last;
      if (choice != _CopyDestinationChoice.change) return null;
    }

    final picked = await pickDestination();
    if (picked != null && picked.isNotEmpty) {
      settings.setLastCopyDestination(picked);
    }
    return picked;
  }

  /// 弹出系统目录选择器（Android 为 SAF，桌面为文件夹选择器）
  static Future<String?> pickDestination() {
    return Platform.isAndroid
        ? MediaStoreService.pickDestinationDir()
        : DirectoryPickerService.pickDirectory();
  }

  /// 把目标目录转成便于阅读的文本（SAF tree uri 解码为可读路径）
  static String displayDestination(String destination) {
    if (!destination.startsWith('content://')) return destination;
    var value = destination;
    final treeIndex = value.indexOf('/tree/');
    if (treeIndex >= 0) value = value.substring(treeIndex + 6);
    final queryIndex = value.indexOf('?');
    if (queryIndex >= 0) value = value.substring(0, queryIndex);
    try {
      value = Uri.decodeComponent(value);
    } catch (_) {}
    return value.replaceAll(':', ' / ');
  }

  /// 桌面端生成不覆盖已有文件的目标路径（重名时追加 _1、_2…）
  static Future<String> uniqueDesktopTarget(String dir, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var candidate = name;
    var index = 1;
    while (await File('$dir${Platform.pathSeparator}$candidate').exists()) {
      candidate = '${base}_$index$ext';
      index++;
    }
    return '$dir${Platform.pathSeparator}$candidate';
  }

  /// 取只含文件名的安全名称，避免远端返回的路径片段被拼进目标路径
  static String fileNameFor(ImageItem item, [int index = 0]) {
    final name = item.name.split(RegExp(r'[\\/]')).last;
    if (name.isEmpty || name == '.' || name == '..') {
      return 'frame_flow_${DateTime.now().microsecondsSinceEpoch}_$index';
    }
    return name;
  }

  /// 下载单张远端图片并写入目标目录，成功返回 true。
  static Future<bool> copyRemoteImage(
    ImageItem item,
    String destination,
  ) async {
    final url = item.remoteUrl;
    if (url == null || url.isEmpty) return false;
    final bytes = await LanClientService.instance.fetchBytes(url);
    if (bytes == null) return false;

    final name = fileNameFor(item);

    if (Platform.isAndroid) {
      // SAF 只接受本地文件：先写入临时目录，再交给系统复制到目标目录
      Directory? tempDir;
      try {
        final root = await getTemporaryDirectory();
        tempDir = await Directory(
          '${root.path}${Platform.pathSeparator}'
          'frame_flow_copy_${DateTime.now().microsecondsSinceEpoch}',
        ).create(recursive: true);
        final tempFile = File('${tempDir.path}${Platform.pathSeparator}$name');
        await tempFile.writeAsBytes(bytes, flush: true);
        return MediaStoreService.copyFiles(destination, [tempFile.path]);
      } catch (_) {
        return false;
      } finally {
        try {
          await tempDir?.delete(recursive: true);
        } catch (_) {}
      }
    }

    try {
      final target = await uniqueDesktopTarget(destination, name);
      await File(target).writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
