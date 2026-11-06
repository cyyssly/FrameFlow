import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/services/explorer_sort_service.dart';
import 'package:frame_flow/services/image_scan_service.dart';

/// 文件直开：根据图片路径构建播放列表并跳转到播放页。
///
/// 核心思路：
/// 1. 取图片的直接父目录
/// 2. 扫描该目录（**不包含子文件夹**），排除记录仍然生效
/// 3. 播放列表按资源管理器当前视图的排序方式排列（名称/修改日期/大小及方向），
///    保证幻灯播放顺序与用户肉眼在资源管理器里看到的顺序一致；
///    读不到（目录未在资源管理器打开、按类型排序等）时回退到名称自然序
/// 4. 定位到用户打开的那张图片，但**不自动播放**，等用户点击播放按钮
class OpenImageFromPath {
  /// Windows 下做大小写不敏感的路径精确匹配。
  static bool _pathEquals(String a, String b) {
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  /// 扫描图片所在的父目录，返回该文件夹内的全部图片。
  ///
  /// 只扫描当前文件夹，不递归子文件夹。
  static Future<List<ImageItem>> scanFolderOf(
    String imagePath,
    SettingsProvider settings,
  ) {
    final parentDir = File(imagePath).parent.path;
    return ImageScanService.scanFolder(
      parentDir,
      settings,
      recursiveOverride: false,
    );
  }

  /// 打开图片：先立即进入播放页显示被打开的图片，再在后台补全播放列表。
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

    // 先用被打开的图片直接进入播放页。同目录扫描在几万张照片的文件夹里
    // 要花数秒，若等扫描结束再跳转，用户会先盯着上一个界面等，
    // 表现为「双击后迟迟不切到新图片」。
    slideProvider.setImages([
      ImageItem(
        name: imagePath.split(Platform.pathSeparator).last,
        path: imagePath,
      ),
    ]);

    if (popFirst && navigator.mounted) {
      navigator.popUntil((route) => route.isFirst);
    }
    if (!navigator.mounted) return;
    // 不自动播放：打开后停在目标图片，由用户点击播放按钮开始
    unawaited(navigator.pushNamed('/player'));

    // 后台补全同目录的播放列表，完成后原地替换（显示中的图片不变）
    final items = await scanFolderOf(imagePath, settings);
    if (items.isEmpty || !navigator.mounted) return;

    // 与用户在资源管理器里看到的顺序保持一致：读取该目录窗口当前的排序列与方向
    final playOrder =
        await ExplorerSortService.readPlayOrder(File(imagePath).parent.path) ??
        PlayOrder.sequential;

    // 扫描期间用户可能已经关掉播放页、或换了别的图片，此时不要覆盖当前列表
    if (slideProvider.images.length != 1 ||
        !_pathEquals(slideProvider.images.first.path, imagePath)) {
      return;
    }

    slideProvider.setImages(items);
    slideProvider.sortByPlayOrder(playOrder);
    final idx = slideProvider.images.indexWhere(
      (image) => _pathEquals(image.path, imagePath),
    );
    slideProvider.goToImage(idx >= 0 ? idx : 0);
  }
}
