import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/services/directory_picker_service.dart';
import 'package:slide_show/services/image_scan_service.dart';
import 'package:slide_show/services/media_store_service.dart';
import 'package:slide_show/widgets/masonry_image_grid.dart';
import 'package:slide_show/l10n/app_localizations.dart';

/// 文件夹图片瀑布流浏览页
/// 提供 4 个操作：排除、删除、移动到、复制到
class FolderImagesScreen extends StatefulWidget {
  final String folderPath;

  const FolderImagesScreen({super.key, required this.folderPath});

  @override
  State<FolderImagesScreen> createState() => _FolderImagesScreenState();
}

class _FolderImagesScreenState extends State<FolderImagesScreen> {
  /// 全部图片（扫描结果）
  List<ImageItem> _allItems = [];

  /// 当前已显示在瀑布流中的图片
  List<ImageItem> _items = [];
  bool _isLoading = true;
  int? _selectedIndex;

  /// 每批加载的图片数量
  static const _pageSize = 30;

  /// 已加载到内存的图片数量（宽高比与预解码都已就绪）
  int _loadedCount = 0;

  /// 是否正在预加载（防止重复触发）
  bool _isPreloading = false;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final items = await ImageScanService.scanFolder(
      widget.folderPath,
      settings,
    );
    if (!mounted) return;
    setState(() {
      _allItems = items;
      _items = items.take(_pageSize).toList();
      // 图片不足一页时不要记成 30，否则 _loadMore 会取到空区间
      _loadedCount = items.length.clamp(0, _pageSize);
      _isLoading = false;
    });
    // 首批：先读出宽高比（决定卡片高度），再真正预解码像素
    await _loadAspectRatios(_items);
    // 预解码当前批，首屏没有滚动通知，必须主动解码
    unawaited(_precacheBatch(_items));
    // 预加载下一批，保证滚动时无需等待
    unawaited(_preloadNextBatch());
  }

  /// 预加载下一批：
  /// 1. 先读出该批的宽高比（决定卡片高度）
  /// 2. 真正解码像素（填充 ImageCache），这是消除滚动卡顿的关键
  /// 3. 两者都就绪后才把该批标记为"可显示"，避免卡片先按正方形渲染再重排跳变
  Future<void> _preloadNextBatch() async {
    if (_isPreloading) return;
    if (_loadedCount >= _allItems.length) return;
    _isPreloading = true;
    try {
      final start = _loadedCount;
      final end = (start + _pageSize).clamp(0, _allItems.length);
      final batch = _allItems.sublist(start, end);
      await _loadAspectRatios(batch);
      await _precacheBatch(batch);
      // 宽高比与像素都已就绪，才允许 _loadMore 把这一批显示出来
      _loadedCount = end;
    } finally {
      _isPreloading = false;
    }
  }

  /// 滚动接近底部时：立即显示已预加载的图片，并预加载下一批
  void _loadMore() {
    if (_items.length >= _allItems.length) return;
    // 显示已预加载的图片（宽高比与像素都已就绪，无跳变、无卡顿）
    final newItems = _allItems.sublist(_items.length, _loadedCount);
    if (newItems.isNotEmpty) {
      setState(() {
        _items.addAll(newItems);
      });
    }
    // 预加载下一批
    unawaited(_preloadNextBatch());
  }

  /// 读取一批图片的宽高比，完成后一次性更新（避免频繁 setState）
  ///
  /// Android 端 MediaStore 已直接给出宽高比，只有未索引到尺寸的图片
  /// 才需要走文件解析，因此这里先过滤再解析。
  Future<void> _loadAspectRatios(List<ImageItem> batch) async {
    final pendingIndexes = <int>[];
    final pendingPaths = <String>[];
    for (var i = 0; i < batch.length; i++) {
      if (batch[i].aspectRatio == null) {
        pendingIndexes.add(i);
        pendingPaths.add(batch[i].path);
      }
    }
    if (pendingPaths.isEmpty) return;

    final ratios = await ImageScanService.readAspectRatios(pendingPaths);
    if (!mounted) return;
    setState(() {
      // 建立 路径→索引 映射，避免逐项 indexWhere 导致 O(n²)
      final allIndexByPath = <String, int>{};
      for (var i = 0; i < _allItems.length; i++) {
        allIndexByPath[_allItems[i].path] = i;
      }
      final itemIndexByPath = <String, int>{};
      for (var i = 0; i < _items.length; i++) {
        itemIndexByPath[_items[i].path] = i;
      }

      for (var k = 0; k < pendingPaths.length; k++) {
        final ratio = ratios[k];
        if (ratio == null) continue;
        final i = pendingIndexes[k];
        final item = batch[i];
        final updated = ImageItem(
          name: item.name,
          path: item.path,
          aspectRatio: ratio,
        );
        // 更新全部列表
        final allIndex = allIndexByPath[item.path];
        if (allIndex != null) _allItems[allIndex] = updated;
        // 更新显示列表
        final index = itemIndexByPath[item.path];
        if (index != null) _items[index] = updated;
        // 同步 batch 内的对象，保证调用方能拿到带宽高比的新对象
        batch[i] = updated;
      }
    });
  }

  /// 预解码指定图片的像素，填充 [ImageCache]
  Future<void> _precacheBatch(List<ImageItem> batch) async {
    if (!mounted || batch.isEmpty) return;
    await MasonryImageGrid.precacheAll(
      batch.map((e) => e.path).toList(),
      context,
    );
  }

  // ── 单图操作 ──
  void _excludeImage(String path) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.addExcludedPath(path);
    setState(() {
      _items.removeWhere((item) => item.path == path);
      _allItems.removeWhere((item) => item.path == path);
    });
    _showSnack(AppLocalizations.of(context).excluded);
  }

  Future<void> _deleteImage(ImageItem item) async {
    final ok = await MediaStoreService.deleteToTrash([item.path]);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).deleteFailed);
      return;
    }
    setState(() {
      _items.removeWhere((i) => i.path == item.path);
      _allItems.removeWhere((i) => i.path == item.path);
    });
    _showSnack(AppLocalizations.of(context).deletedToTrash);
  }

  Future<void> _moveImage(ImageItem item) async {
    // Android 用 SAF 选择可写目录（tree uri），其他平台用 FilePicker 选择路径
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final ok = await MediaStoreService.moveFiles(result, [item.path]);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).moveFailed);
      return;
    }
    setState(() {
      _items.removeWhere((i) => i.path == item.path);
      _allItems.removeWhere((i) => i.path == item.path);
    });
  }

  Future<void> _copyImage(ImageItem item) async {
    // Android 用 SAF 选择可写目录（tree uri），其他平台用 FilePicker 选择路径
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final ok = await MediaStoreService.copyFiles(result, [item.path]);
    if (!mounted) return;
    if (ok) {
      _showSnack(AppLocalizations.of(context).copySuccess);
    } else {
      _showSnack(AppLocalizations.of(context).copyFailed);
    }
  }

  /// 选择移动/复制目标目录。
  /// Android 用原生 SAF 返回 content:// tree uri；其他平台用 FilePicker 返回路径。
  /// @return 目标标识（tree uri 或路径），取消返回 null
  Future<String?> _pickDestination() async {
    if (Platform.isAndroid) {
      return MediaStoreService.pickDestinationDir();
    }
    return DirectoryPickerService.pickDirectory();
  }

  // ── 批量操作（作用于全部图片） ──
  Future<void> _excludeAll() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    for (final item in _allItems) {
      settings.addExcludedPath(item.path);
    }
    setState(() {
      _items.clear();
      _allItems.clear();
    });
    _showSnack(AppLocalizations.of(context).allExcluded);
  }

  Future<void> _deleteAll() async {
    final paths = _allItems.map((e) => e.path).toList();
    final ok = await MediaStoreService.deleteToTrash(paths);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).deleteFailed);
      return;
    }
    setState(() {
      _items.clear();
      _allItems.clear();
    });
    _showSnack(AppLocalizations.of(context).deletedAllToTrash);
  }

  Future<void> _moveAll() async {
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final items = List<ImageItem>.from(_allItems);
    final ok = await MediaStoreService.moveFiles(
      result,
      items.map((e) => e.path).toList(),
    );
    if (!mounted) return;
    if (ok) {
      setState(() {
        _items.clear();
        _allItems.clear();
      });
      _showSnack(AppLocalizations.of(context).movedAllTo);
    } else {
      _showSnack(AppLocalizations.of(context).moveFailed);
    }
  }

  Future<void> _copyAll() async {
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final items = List<ImageItem>.from(_allItems);
    final ok = await MediaStoreService.copyFiles(
      result,
      items.map((e) => e.path).toList(),
    );
    if (!mounted) return;
    if (ok) {
      _showSnack(AppLocalizations.of(context).copiedAllTo);
    } else {
      _showSnack(AppLocalizations.of(context).copyFailed);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          Platform.isAndroid
              ? _getLastPathSegment(widget.folderPath)
              : widget.folderPath,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        actions: [
          if (_items.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.block, color: Colors.orange),
              tooltip: loc.excludeAll,
              onPressed: _excludeAll,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: loc.deleteAll,
              onPressed: _deleteAll,
            ),
            IconButton(
              icon: const Icon(
                Icons.drive_file_move_outline,
                color: Colors.lightBlue,
              ),
              tooltip: loc.moveAllTo,
              onPressed: _moveAll,
            ),
            IconButton(
              icon: const Icon(Icons.content_copy, color: Colors.greenAccent),
              tooltip: loc.copyAllTo,
              onPressed: _copyAll,
            ),
          ],
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.image, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    loc.noImagesInFolder,
                    style: const TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            )
          : MasonryImageGrid(
              items: _items,
              selectedIndex: _selectedIndex,
              hasMore: _items.length < _allItems.length,
              onLoadMore: _loadMore,
              onTap: (index) {
                setState(() {
                  _selectedIndex = _selectedIndex == index ? null : index;
                });
              },
              onPrimaryAction: (index) {
                _excludeImage(_items[index].path);
                if (mounted) setState(() => _selectedIndex = null);
              },
              onDelete: (index) {
                _deleteImage(_items[index]);
                if (mounted) setState(() => _selectedIndex = null);
              },
              onMove: (index) {
                _moveImage(_items[index]);
                if (mounted) setState(() => _selectedIndex = null);
              },
              onCopy: (index) {
                _copyImage(_items[index]);
              },
              primaryIcon: Icons.block,
              primaryColor: Colors.orange,
              primaryTooltip: loc.excludeFromPlay,
            ),
    );
  }

  /// 提取路径的最后一级目录名（兼容 / 和 \ 分隔符）
  String _getLastPathSegment(String path) {
    var clean = path;
    while (clean.endsWith('/') || clean.endsWith('\\')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final lastIndex = clean.lastIndexOf(RegExp(r'[/\\]'));
    return lastIndex >= 0 ? clean.substring(lastIndex + 1) : clean;
  }
}
