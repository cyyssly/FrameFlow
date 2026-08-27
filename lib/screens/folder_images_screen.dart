import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/providers/settings_provider.dart';
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

  /// 已加载到内存的图片数量（含预加载的下一批）
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
      _loadedCount = _pageSize;
      _isLoading = false;
    });
    // 串行读取当前批次的宽高比（后台执行，不阻塞 UI）
    _loadAspectRatios(_items);
    // 预加载下一批，保证滚动时无需等待
    _preloadNextBatch();
  }

  /// 预加载下一批图片到内存（不显示，仅读取宽高比）
  Future<void> _preloadNextBatch() async {
    if (_isPreloading) return;
    if (_loadedCount >= _allItems.length) return;
    _isPreloading = true;
    final start = _loadedCount;
    final end = (start + _pageSize).clamp(0, _allItems.length);
    _loadedCount = end;
    final batch = _allItems.sublist(start, end);
    // 后台串行读取宽高比
    await _loadAspectRatios(batch);
    _isPreloading = false;
  }

  /// 滚动到底部时：立即显示已预加载的图片，并预加载下一批
  void _loadMore() {
    if (_items.length >= _allItems.length) return;
    // 显示已预加载的图片（立即，无延迟）
    final newItems = _allItems.sublist(_items.length, _loadedCount);
    setState(() {
      _items.addAll(newItems);
    });
    // 预加载下一批
    _preloadNextBatch();
  }

  /// 串行读取一批图片的宽高比，完成后一次性更新（避免频繁 setState）
  Future<void> _loadAspectRatios(List<ImageItem> batch) async {
    final ratios = await ImageScanService.readAspectRatios(
      batch.map((e) => e.path).toList(),
    );
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < batch.length; i++) {
        final ratio = ratios[i];
        if (ratio == null) continue;
        final item = batch[i];
        final updated = ImageItem(
          name: item.name,
          path: item.path,
          aspectRatio: ratio,
        );
        // 更新全部列表
        final allIndex = _allItems.indexWhere((e) => e.path == item.path);
        if (allIndex >= 0) _allItems[allIndex] = updated;
        // 更新显示列表
        final index = _items.indexWhere((e) => e.path == item.path);
        if (index >= 0) _items[index] = updated;
      }
    });
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
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    if (!mounted) return;
    try {
      final file = File(item.path);
      final newPath = '$result\\${item.name}';
      await file.copy(newPath);
      await file.delete();
    } catch (_) {
      if (mounted) _showSnack(AppLocalizations.of(context).moveFailed);
      return;
    }
    if (!mounted) return;
    setState(() {
      _items.removeWhere((i) => i.path == item.path);
      _allItems.removeWhere((i) => i.path == item.path);
    });
  }

  Future<void> _copyImage(ImageItem item) async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    if (!mounted) return;
    try {
      final file = File(item.path);
      final newPath = '$result\\${item.name}';
      await file.copy(newPath);
    } catch (_) {
      if (mounted) _showSnack(AppLocalizations.of(context).copyFailed);
      return;
    }
    if (mounted) _showSnack(AppLocalizations.of(context).copySuccess);
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
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    if (!mounted) return;
    final items = List<ImageItem>.from(_allItems);
    for (final item in items) {
      try {
        final file = File(item.path);
        final newPath = '$result\\${item.name}';
        await file.copy(newPath);
        await file.delete();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _items.clear();
      _allItems.clear();
    });
    _showSnack(AppLocalizations.of(context).movedAllTo);
  }

  Future<void> _copyAll() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    if (!mounted) return;
    final items = List<ImageItem>.from(_allItems);
    for (final item in items) {
      try {
        final file = File(item.path);
        final newPath = '$result\\${item.name}';
        await file.copy(newPath);
      } catch (_) {}
    }
    if (!mounted) return;
    _showSnack(AppLocalizations.of(context).copiedAllTo);
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
