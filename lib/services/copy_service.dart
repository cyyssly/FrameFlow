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

/// 同名文件冲突的用户选择
enum CopyConflictChoice { replaceAll, skipAll, replaceOne, skipOne, cancel }

/// 一批复制/移动的同名冲突处理结果
class CopyConflictPlan {
  const CopyConflictPlan({
    required this.replace,
    required this.skip,
    required this.cancelled,
  });

  /// 需要覆盖写入的文件名
  final Set<String> replace;

  /// 需要跳过的文件名
  final Set<String> skip;

  /// 用户是否取消了整个操作
  final bool cancelled;
}

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

  /// 统计本次写入中与目标同名的文件，并让用户决定替换或跳过。
  ///
  /// [names] 为本次要写入的文件名（按写入顺序），[existing] 为目标目录
  /// 中已存在的文件名。批量操作时 [batch] 为 true，弹窗会给出同名文件
  /// 数量，并提供「全部替换 / 全部跳过 / 替换本张 / 跳过本张 / 取消」；
  /// 同一批内出现多次的文件名同样按冲突处理，否则后一张会覆盖前一张。
  static Future<CopyConflictPlan> resolveConflicts(
    BuildContext context, {
    required String title,
    required List<String> names,
    required Set<String> existing,
    required bool batch,
  }) async {
    final loc = AppLocalizations.of(context);
    final counts = <String, int>{};
    for (final name in names) {
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final conflicts = [
      for (final entry in counts.entries)
        if (existing.contains(entry.key) || entry.value > 1) entry.key,
    ];
    if (conflicts.isEmpty) {
      return const CopyConflictPlan(replace: {}, skip: {}, cancelled: false);
    }

    final conflicting = conflicts.fold<int>(
      0,
      (sum, name) => sum + (counts[name] ?? 0),
    );
    var replaceAll = false;
    var skipAll = false;
    final replace = <String>{};
    final skip = <String>{};

    for (final name in conflicts) {
      if (replaceAll) {
        replace.add(name);
        continue;
      }
      if (skipAll) {
        skip.add(name);
        continue;
      }
      if (!context.mounted) {
        return CopyConflictPlan(replace: replace, skip: skip, cancelled: true);
      }
      final choice = await showDialog<CopyConflictChoice>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                batch
                    ? loc.conflictBatch(conflicting, names.length)
                    : loc.conflictSingle(name),
              ),
              if (batch) ...[
                const SizedBox(height: 8),
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ],
          ),
          actions: batch
              ? [
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.cancel),
                    child: Text(loc.cancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.skipAll),
                    child: Text(loc.skipAll),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.replaceAll),
                    child: Text(loc.replaceAll),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.skipOne),
                    child: Text(loc.skipThis),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.replaceOne),
                    child: Text(loc.replaceThis),
                  ),
                ]
              : [
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.cancel),
                    child: Text(loc.cancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.skipOne),
                    child: Text(loc.skipFile),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.replaceOne),
                    child: Text(loc.replaceFile),
                  ),
                ],
        ),
      );
      switch (choice) {
        case CopyConflictChoice.replaceAll:
          replaceAll = true;
          replace.add(name);
          break;
        case CopyConflictChoice.skipAll:
          skipAll = true;
          skip.add(name);
          break;
        case CopyConflictChoice.replaceOne:
          replace.add(name);
          break;
        case CopyConflictChoice.skipOne:
          skip.add(name);
          break;
        case CopyConflictChoice.cancel:
        case null:
          return CopyConflictPlan(
            replace: replace,
            skip: skip,
            cancelled: true,
          );
      }
    }
    return CopyConflictPlan(replace: replace, skip: skip, cancelled: false);
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
  ///
  /// [overwrite] 为 true 时覆盖目标目录中的同名文件；
  /// 为 false 时调用方应已确认目标不存在同名文件。
  static Future<bool> copyRemoteImage(
    ImageItem item,
    String destination, {
    bool overwrite = false,
  }) async {
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
        return MediaStoreService.copyFiles(
          destination,
          [tempFile.path],
          displayNames: [name],
          overwriteNames: overwrite ? {name} : const {},
        );
      } catch (_) {
        return false;
      } finally {
        try {
          await tempDir?.delete(recursive: true);
        } catch (_) {}
      }
    }

    try {
      final target = '$destination${Platform.pathSeparator}$name';
      await File(target).writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
