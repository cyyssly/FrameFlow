import 'dart:io';

import 'package:flutter/material.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/services/image_scan_service.dart';

/// 文件直开：根据图片路径构建播放列表并跳转到播放页。
///
/// 核心思路：
/// 1. 取图片的直接父目录
/// 2. 扫描该目录（**不包含子文件夹**），排除记录仍然生效
/// 3. 播放列表按该文件夹记录的排序方式排列；没有记录时跟随设置页的默认播放顺序
/// 4. 定位到用户打开的那张图片，但**不自动播放**，等用户点击播放按钮
class OpenImageFromPath {
  /// 把 [SettingsProvider.localSortFor] 返回的排序名字符串（来自
  /// `folder_images_screen.dart` 内部枚举 `_SortAction` 的 `.name`）
  /// 反查为 [PlayOrder]；未知或 null 时回退到 [fallback]（通常是
  /// [SettingsProvider.playOrder]）。
  static PlayOrder playOrderForSortName(
    String? sortName, {
    required PlayOrder fallback,
  }) {
    if (sortName == null) return fallback;
    switch (sortName) {
      case 'nameAsc':
        return PlayOrder.sequential;
      case 'nameDesc':
        return PlayOrder.reverseSequential;
      case 'timeNewest':
        return PlayOrder.newestFirst;
      case 'timeOldest':
        return PlayOrder.oldestFirst;
      case 'sizeLargest':
        return PlayOrder.sizeLargest;
      case 'sizeSmallest':
        return PlayOrder.sizeSmallest;
      case 'random':
        return PlayOrder.random;
      case 'newPreferred':
        return PlayOrder.newPreferred;
      default:
        return fallback;
    }
  }

  /// Windows 下做大小写不敏感的路径精确匹配。
  static bool _pathEquals(String a, String b) {
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  /// 扫描图片所在的父目录，并返回「图片列表」与「应使用的排序方式」。
  static Future<(List<ImageItem>, PlayOrder)> scanWithOrder(
    String imagePath,
    SettingsProvider settings,
  ) async {
    final parentDir = File(imagePath).parent.path;
    // 只扫描当前文件夹，不递归子文件夹
    final items = await ImageScanService.scanFolder(
      parentDir,
      settings,
      recursiveOverride: false,
    );
    final order = playOrderForSortName(
      settings.localSortFor(parentDir),
      fallback: settings.playOrder,
    );
    return (items, order);
  }

  /// 打开图片：构建播放列表，定位到入口图片，导航到播放页。
  ///
  /// - [popFirst] 跳转前是否先 pop 到根路由。单实例转发场景需要清掉
  ///   当前可能残留的播放页；新实例首次启动不需要。
  static Future<void> openImage({
    required NavigatorState navigator,
    required SlideProvider slideProvider,
    required SettingsProvider settings,
    required String imagePath,
    bool popFirst = false,
  }) async {
    // 打开的图片若属于某个媒体库，先切到该库，让界面与播放内容一致；
    // 不在任何库内则保持当前库不变。
    if (settings.switchToLibraryForPath(imagePath)) {
      slideProvider.setFolderPaths(settings.lastFolderPaths);
    }

    final (items, order) = await scanWithOrder(imagePath, settings);

    if (popFirst && navigator.mounted) {
      navigator.popUntil((route) => route.isFirst);
    }

    if (items.isEmpty) {
      // 扫描不到同目录图片（目录不可读等）时，至少播放被打开的这一张
      slideProvider.setImages([
        ImageItem(
          name: imagePath.split(Platform.pathSeparator).last,
          path: imagePath,
        ),
      ]);
    } else {
      slideProvider.setImages(items);
      slideProvider.sortByPlayOrder(order);
      final idx = slideProvider.images.indexWhere(
        (image) => _pathEquals(image.path, imagePath),
      );
      slideProvider.goToImage(idx >= 0 ? idx : 0);
    }
    // 不调用 startPlay：打开后停在目标图片，由用户点击播放按钮开始

    if (navigator.mounted) {
      navigator.pushNamed('/player');
    }
  }
}
