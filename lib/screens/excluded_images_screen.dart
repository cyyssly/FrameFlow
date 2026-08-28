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

class ExcludedImagesScreen extends StatefulWidget {
  const ExcludedImagesScreen({super.key});

  @override
  State<ExcludedImagesScreen> createState() => _ExcludedImagesScreenState();
}

class _ExcludedImagesScreenState extends State<ExcludedImagesScreen> {
  List<ImageItem> _excludedItems = [];
  bool _isLoading = true;
  int? _selectedIndex;

  @override
  void initState() {
    super.initState();
    _loadExcludedImages();
  }

  void _loadExcludedImages() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final items = <ImageItem>[];
    for (final path in settings.excludedPaths) {
      final file = File(path);
      if (file.existsSync()) {
        items.add(
          ImageItem(name: path.split(Platform.pathSeparator).last, path: path),
        );
      }
    }
    setState(() {
      _excludedItems = items;
      _isLoading = false;
    });
    // 异步读取每张图片的宽高比，用于瀑布流布局
    for (final item in items) {
      _loadAspectRatio(item);
    }
  }

  Future<void> _loadAspectRatio(ImageItem item) async {
    final ratio = await ImageScanService.readAspectRatio(item.path);
    if (!mounted) return;
    final index = _excludedItems.indexWhere((i) => i.path == item.path);
    if (index < 0) return;
    setState(() {
      _excludedItems[index] = ImageItem(
        name: item.name,
        path: item.path,
        aspectRatio: ratio,
      );
    });
  }

  // ── 单图操作 ──
  void _restoreImage(String path) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(path);
    setState(() => _excludedItems.removeWhere((item) => item.path == path));
    _showSnack(AppLocalizations.of(context).imageRestored);
  }

  Future<void> _deleteImage(ImageItem item) async {
    final ok = await MediaStoreService.deleteToTrash([item.path]);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).deleteFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(item.path);
    setState(() => _excludedItems.removeWhere((i) => i.path == item.path));
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
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(item.path);
    setState(() => _excludedItems.removeWhere((i) => i.path == item.path));
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
    return FilePicker.platform.getDirectoryPath();
  }

  // ── 批量操作 ──
  Future<void> _restoreAll() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).allImagesRestored);
  }

  Future<void> _deleteAll() async {
    final paths = _excludedItems.map((e) => e.path).toList();
    final ok = await MediaStoreService.deleteToTrash(paths);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).deleteFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).deletedAllToTrash);
  }

  Future<void> _moveAll() async {
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final items = List<ImageItem>.from(_excludedItems);
    final ok = await MediaStoreService.moveFiles(
      result,
      items.map((e) => e.path).toList(),
    );
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).moveFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).movedAllTo);
  }

  Future<void> _copyAll() async {
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final items = List<ImageItem>.from(_excludedItems);
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
        title: Text(loc.excludedFolder),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        actions: [
          if (_excludedItems.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.restore, color: Colors.orange),
              tooltip: loc.restoreAll,
              onPressed: _restoreAll,
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
          : _excludedItems.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.inbox, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    loc.noExcludedImages,
                    style: const TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            )
          : MasonryImageGrid(
              items: _excludedItems,
              selectedIndex: _selectedIndex,
              onTap: (index) {
                setState(() {
                  _selectedIndex = _selectedIndex == index ? null : index;
                });
              },
              onPrimaryAction: (index) {
                _restoreImage(_excludedItems[index].path);
                if (mounted) setState(() => _selectedIndex = null);
              },
              onDelete: (index) {
                _deleteImage(_excludedItems[index]);
                if (mounted) setState(() => _selectedIndex = null);
              },
              onMove: (index) {
                _moveImage(_excludedItems[index]);
                if (mounted) setState(() => _selectedIndex = null);
              },
              onCopy: (index) {
                _copyImage(_excludedItems[index]);
              },
              primaryIcon: Icons.restore,
              primaryColor: Colors.orange,
              primaryTooltip: loc.restore,
            ),
    );
  }
}
