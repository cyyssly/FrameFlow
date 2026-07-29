import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/providers/settings_provider.dart';
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
  }

  // ── 单图操作 ──
  void _restoreImage(String path) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(path);
    setState(() => _excludedItems.removeWhere((item) => item.path == path));
    _showSnack(AppLocalizations.of(context).imageRestored);
  }

  Future<void> _deleteImage(ImageItem item) async {
    try {
      await File(item.path).delete();
    } catch (_) {}
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(item.path);
    setState(() => _excludedItems.removeWhere((i) => i.path == item.path));
  }

  Future<void> _moveImage(ImageItem item) async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    try {
      final file = File(item.path);
      final newPath = '$result\\${item.name}';
      await file.copy(newPath);
      await file.delete();
    } catch (_) {
      if (mounted) _showSnack(AppLocalizations.of(context).moveFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(item.path);
    setState(() => _excludedItems.removeWhere((i) => i.path == item.path));
  }

  Future<void> _copyImage(ImageItem item) async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
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

  // ── 批量操作 ──
  Future<void> _restoreAll() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).allImagesRestored);
  }

  Future<void> _deleteAll() async {
    for (final item in _excludedItems) {
      try {
        await File(item.path).delete();
      } catch (_) {}
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).deletedAll);
  }

  Future<void> _moveAll() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    final items = List<ImageItem>.from(_excludedItems);
    for (final item in items) {
      try {
        final file = File(item.path);
        final newPath = '$result\\${item.name}';
        await file.copy(newPath);
        await file.delete();
      } catch (_) {}
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).movedAllTo);
  }

  Future<void> _copyAll() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    final items = List<ImageItem>.from(_excludedItems);
    for (final item in items) {
      try {
        final file = File(item.path);
        final newPath = '$result\\${item.name}';
        await file.copy(newPath);
      } catch (_) {}
    }
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
          : LayoutBuilder(
              builder: (context, constraints) {
                // 窄屏（<800px）固定2列，否则每400px一列
                final crossAxisCount = constraints.maxWidth < 800
                    ? 2
                    : (constraints.maxWidth / 400).floor().clamp(2, 10);
                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _excludedItems.length,
                  itemBuilder: (context, index) {
                    final item = _excludedItems[index];
                    return _ExcludedImageCard(
                      item: item,
                      isSelected: _selectedIndex == index,
                      onTap: () {
                        setState(() {
                          _selectedIndex = _selectedIndex == index
                              ? null
                              : index;
                        });
                      },
                      onRestore: () {
                        _restoreImage(item.path);
                        if (mounted) setState(() => _selectedIndex = null);
                      },
                      onDelete: () {
                        _deleteImage(item);
                        if (mounted) setState(() => _selectedIndex = null);
                      },
                      onMove: () {
                        _moveImage(item);
                        if (mounted) setState(() => _selectedIndex = null);
                      },
                      onCopy: () {
                        _copyImage(item);
                      },
                    );
                  },
                );
              },
            ),
    );
  }
}

// ── 单个图片卡片（PC悬停 / 移动端点击选中 显示覆盖层） ──
class _ExcludedImageCard extends StatefulWidget {
  final ImageItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback onCopy;

  const _ExcludedImageCard({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.onRestore,
    required this.onDelete,
    required this.onMove,
    required this.onCopy,
  });

  @override
  State<_ExcludedImageCard> createState() => _ExcludedImageCardState();
}

class _ExcludedImageCardState extends State<_ExcludedImageCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Card(
          elevation: widget.isSelected ? 8 : 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: widget.isSelected
                ? const BorderSide(color: Colors.orange, width: 2)
                : BorderSide.none,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(widget.item.path),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                ),
                // 悬停 或 选中 时显示覆盖层
                if (_isHovered || widget.isSelected) _buildOverlay(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final restore = widget.onRestore;
    final delete = widget.onDelete;
    final move = widget.onMove;
    final copy = widget.onCopy;
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _iconButton(Icons.restore, Colors.orange, loc.restore, restore),
                const SizedBox(width: 8),
                _iconButton(
                  Icons.delete_outline,
                  Colors.redAccent,
                  loc.deleteImage,
                  delete,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _iconButton(
                  Icons.drive_file_move_outline,
                  Colors.lightBlue,
                  loc.moveTo,
                  move,
                ),
                const SizedBox(width: 8),
                _iconButton(
                  Icons.content_copy,
                  Colors.greenAccent,
                  loc.copyTo,
                  copy,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconButton(
    IconData icon,
    Color color,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Material(
          color: Colors.black.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onPressed,
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}
