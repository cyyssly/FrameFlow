import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:frame_flow/l10n/app_localizations.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/models/lan_models.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/screens/player_screen.dart';
import 'package:frame_flow/services/directory_picker_service.dart';
import 'package:frame_flow/services/fullscreen_service.dart';
import 'package:frame_flow/services/lan_client_service.dart';
import 'package:frame_flow/services/media_store_service.dart';
import 'package:frame_flow/widgets/masonry_image_grid.dart';
import 'package:frame_flow/widgets/sort_alphabet_icon.dart';

/// 远端设备的共享文件夹列表
class RemoteFoldersScreen extends StatefulWidget {
  final LanDevice device;

  /// 选择模式：点击文件夹后加入本机播放列表，而不是浏览图片
  final bool selectMode;

  const RemoteFoldersScreen({
    super.key,
    required this.device,
    this.selectMode = false,
  });

  @override
  State<RemoteFoldersScreen> createState() => _RemoteFoldersScreenState();
}

class _RemoteFoldersScreenState extends State<RemoteFoldersScreen> {
  List<RemoteFolder> _folders = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final folders = await LanClientService.instance.fetchFolders(widget.device);
    if (!mounted) return;
    setState(() {
      _folders = folders ?? const [];
      _failed = folders == null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: loc.lanRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(loc),
    );
  }

  Future<void> _toggleSelection(RemoteFolder folder, bool selected) async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final key = '${widget.device.id}/${folder.id}';
    if (selected) {
      settings.removeSharedFolder(key);
      return;
    }
    settings.addSharedFolder(
      SharedFolderRef(
        deviceId: widget.device.id,
        deviceName: widget.device.name,
        host: widget.device.host,
        port: widget.device.port,
        folderId: folder.id,
        folderName: folder.name,
        imageCount: folder.imageCount,
      ),
    );
  }

  Widget _buildBody(AppLocalizations loc) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return _FailedView(message: loc.lanLoadFailed, onRetry: _load);
    }
    if (_folders.isEmpty) {
      return Center(
        child: Text(
          loc.lanNoFolders,
          style: const TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    final settings = Provider.of<SettingsProvider>(context);
    final selectedIds = widget.selectMode
        ? settings.sharedFolders
              .where((ref) => ref.deviceId == widget.device.id)
              .map((ref) => ref.folderId)
              .toSet()
        : const <String>{};

    final list = ListView.separated(
      itemCount: _folders.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final folder = _folders[index];
        final selected = selectedIds.contains(folder.id);
        return ListTile(
          leading: Icon(
            Icons.folder_open,
            color: selected ? const Color(0xFF00b894) : const Color(0xFF0984e3),
          ),
          title: Text(folder.name),
          subtitle: Text(loc.imagesCount(folder.imageCount)),
          trailing: widget.selectMode
              ? IconButton(
                  tooltip: selected ? loc.lanRemove : loc.lanAdd,
                  icon: Icon(
                    selected ? Icons.check_circle : Icons.add_circle_outline,
                    color: selected ? const Color(0xFF00b894) : Colors.grey,
                  ),
                  onPressed: () => _toggleSelection(folder, selected),
                )
              : const Icon(Icons.chevron_right),
          onTap: widget.selectMode
              ? () => _toggleSelection(folder, selected)
              : () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RemoteImagesScreen(
                        device: widget.device,
                        folder: folder,
                      ),
                    ),
                  );
                },
        );
      },
    );

    if (!widget.selectMode) return list;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 18, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  loc.lanSelectSharedFoldersHint,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );
  }
}

/// 远端文件夹的瀑布流浏览与播放页
class RemoteImagesScreen extends StatefulWidget {
  final LanDevice device;
  final RemoteFolder folder;

  const RemoteImagesScreen({
    super.key,
    required this.device,
    required this.folder,
  });

  @override
  State<RemoteImagesScreen> createState() => _RemoteImagesScreenState();
}

class _RemoteImagesScreenState extends State<RemoteImagesScreen> {
  static const int _pageSize = 60;

  final List<ImageItem> _items = [];
  int _total = 0;
  bool _loading = true;
  bool _failed = false;
  bool _loadingMore = false;
  bool _startingPlayback = false;
  bool _copyingAll = false;

  /// 移动端当前选中的图片；选中后显示右下角的复制按钮
  int? _selectedIndex;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// 排序方式：null 表示使用服务端默认顺序
  String? _sortKey;

  /// 顺序模式下是否为升序（true = 顺序，false = 逆序）
  bool _nameAscending = true;

  /// 日期模式下是否最新在前（true = 最新，false = 最旧）
  bool _newestFirst = true;

  /// 大小模式下是否最大在前（true = 最大，false = 最小）
  bool _largestFirst = true;

  /// 随机排序的固定种子，保证同一次浏览的后续分页顺序一致
  String _randomSeed = '';

  /// 首屏加载代次：快速切换排序时丢弃已过期的响应
  int _loadGeneration = 0;

  /// 当前排序方向（服务端入参）
  String get _sortOrder {
    switch (_sortKey) {
      case 'name':
        return _nameAscending ? 'asc' : 'desc';
      case 'time':
        return _newestFirst ? 'desc' : 'asc';
      case 'size':
        return _largestFirst ? 'desc' : 'asc';
      default:
        return 'asc';
    }
  }

  @override
  void initState() {
    super.initState();
    _loadFirstPage();
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    super.dispose();
  }

  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f11) {
      if (FullscreenService.instance.isFullscreen) {
        FullscreenService.instance.exit();
      } else {
        FullscreenService.instance.enter();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return true;
    }
    return false;
  }

  /// 按当前排序参数请求一页；排序在服务端完成，分页顺序始终一致
  Future<RemoteImagePage?> _fetchPage({
    required int offset,
    required int limit,
  }) {
    return LanClientService.instance.fetchImages(
      widget.device,
      folderId: widget.folder.id,
      offset: offset,
      limit: limit,
      sort: _sortKey,
      order: _sortKey == null ? null : _sortOrder,
      seed: _sortKey == 'random' ? _randomSeed : null,
    );
  }

  Future<void> _loadFirstPage() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _failed = false;
      _loadingMore = false;
      _selectedIndex = null;
    });
    final page = await _fetchPage(offset: 0, limit: _pageSize);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _items
        ..clear()
        ..addAll(page?.items ?? const []);
      _total = page?.total ?? 0;
      _failed = page == null;
      _loading = false;
    });
    if (page != null) _precache(page.items);
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _failed) return;
    if (_items.length >= _total) return;
    final generation = _loadGeneration;
    setState(() => _loadingMore = true);
    final page = await _fetchPage(offset: _items.length, limit: _pageSize);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loadingMore = false;
      if (page != null && page.items.isNotEmpty) {
        _total = page.total;
        _items.addAll(page.items);
      } else {
        // 无法继续加载时停止触发
        _total = _items.length;
      }
    });
    if (page != null && page.items.isNotEmpty) _precache(page.items);
  }

  // ── 排序 ──

  /// 应用菜单中选中的排序方式
  void _applySort(_RemoteSortAction action) {
    setState(() {
      switch (action) {
        case _RemoteSortAction.nameAsc:
          _sortKey = 'name';
          _nameAscending = true;
        case _RemoteSortAction.nameDesc:
          _sortKey = 'name';
          _nameAscending = false;
        case _RemoteSortAction.timeNewest:
          _sortKey = 'time';
          _newestFirst = true;
        case _RemoteSortAction.timeOldest:
          _sortKey = 'time';
          _newestFirst = false;
        case _RemoteSortAction.sizeLargest:
          _sortKey = 'size';
          _largestFirst = true;
        case _RemoteSortAction.sizeSmallest:
          _sortKey = 'size';
          _largestFirst = false;
        case _RemoteSortAction.random:
          _sortKey = 'random';
          // 每次选择随机都换一个种子，保证分页顺序一致
          _randomSeed = DateTime.now().microsecondsSinceEpoch.toString();
      }
    });
    _loadFirstPage();
  }

  /// 当前生效的排序方式
  bool _isSortActive(_RemoteSortAction action) {
    switch (action) {
      case _RemoteSortAction.nameAsc:
        // 未指定排序时服务端按名称升序返回，与“顺序”一致
        return _sortKey == null || (_sortKey == 'name' && _nameAscending);
      case _RemoteSortAction.nameDesc:
        return _sortKey == 'name' && !_nameAscending;
      case _RemoteSortAction.timeNewest:
        return _sortKey == 'time' && _newestFirst;
      case _RemoteSortAction.timeOldest:
        return _sortKey == 'time' && !_newestFirst;
      case _RemoteSortAction.sizeLargest:
        return _sortKey == 'size' && _largestFirst;
      case _RemoteSortAction.sizeSmallest:
        return _sortKey == 'size' && !_largestFirst;
      case _RemoteSortAction.random:
        return _sortKey == 'random';
    }
  }

  PopupMenuItem<_RemoteSortAction> _sortMenuItem({
    required _RemoteSortAction action,
    required String label,
    required Widget Function(Color color) iconBuilder,
  }) {
    final selected = _isSortActive(action);
    final color = selected ? const Color(0xFFe94560) : Colors.white70;
    return PopupMenuItem<_RemoteSortAction>(
      value: action,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Center(child: iconBuilder(color)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          if (selected) Icon(Icons.check, color: color, size: 18),
        ],
      ),
    );
  }

  /// 排序入口：用一个按钮弹出 7 种排序方式，避免占用过多标题栏空间
  Widget _buildSortMenu(AppLocalizations loc) {
    return PopupMenuButton<_RemoteSortAction>(
      tooltip: loc.sortBy,
      icon: const Icon(Icons.sort, color: Colors.white70),
      onSelected: _applySort,
      itemBuilder: (context) => [
        _sortMenuItem(
          action: _RemoteSortAction.nameAsc,
          label: loc.sortSequential,
          iconBuilder: (color) =>
              SortAlphabetIcon(ascending: true, color: color),
        ),
        _sortMenuItem(
          action: _RemoteSortAction.nameDesc,
          label: loc.sortReverse,
          iconBuilder: (color) =>
              SortAlphabetIcon(ascending: false, color: color),
        ),
        _sortMenuItem(
          action: _RemoteSortAction.timeNewest,
          label: loc.sortNewest,
          iconBuilder: (color) => Icon(Icons.update, color: color),
        ),
        _sortMenuItem(
          action: _RemoteSortAction.timeOldest,
          label: loc.sortOldest,
          iconBuilder: (color) => Icon(Icons.history, color: color),
        ),
        _sortMenuItem(
          action: _RemoteSortAction.sizeLargest,
          label: loc.sortLargest,
          iconBuilder: (color) => Icon(Icons.south, color: color),
        ),
        _sortMenuItem(
          action: _RemoteSortAction.sizeSmallest,
          label: loc.sortSmallest,
          iconBuilder: (color) => Icon(Icons.north, color: color),
        ),
        _sortMenuItem(
          action: _RemoteSortAction.random,
          label: loc.sortRandom,
          iconBuilder: (color) => Icon(Icons.shuffle, color: color),
        ),
      ],
    );
  }

  void _precache(List<ImageItem> items) {
    if (items.isEmpty) return;
    unawaited(MasonryImageGrid.precacheItems(items, context, concurrency: 4));
  }

  /// 把远端图片复制到本机选定的目录
  Future<void> _copyImage(ImageItem item) async {
    final loc = AppLocalizations.of(context);
    final sourceUrl = item.remoteUrl;
    if (sourceUrl == null) return;

    // 先选择目标目录，避免大图下载完成后才让用户选择
    final destination = Platform.isAndroid
        ? await MediaStoreService.pickDestinationDir()
        : await DirectoryPickerService.pickDirectory();
    if (destination == null || !mounted) return;

    final bytes = await LanClientService.instance.fetchBytes(sourceUrl);
    if (!mounted) return;
    if (bytes == null) {
      _showSnack(loc.copyFailed);
      return;
    }

    // 只取远端文件名，避免返回的路径片段被拼进目标路径
    final name = _fileNameFor(item, 0);
    var ok = false;
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
        ok = await MediaStoreService.copyFiles(destination, [tempFile.path]);
      } catch (_) {
        ok = false;
      } finally {
        try {
          await tempDir?.delete(recursive: true);
        } catch (_) {}
      }
    } else {
      try {
        await File(
          '$destination${Platform.pathSeparator}$name',
        ).writeAsBytes(bytes, flush: true);
        ok = true;
      } catch (_) {
        ok = false;
      }
    }

    if (!mounted) return;
    _showSnack(ok ? loc.copySuccess : loc.copyFailed);
  }

  /// 远端文件名只保留 basename，空名或相对路径片段则生成兜底名称
  String _fileNameFor(ImageItem item, int index) {
    final name = item.name.split(RegExp(r'[\\/]')).last;
    if (name.isEmpty || name == '.' || name == '..') {
      return 'frame_flow_${DateTime.now().microsecondsSinceEpoch}_$index';
    }
    return name;
  }

  /// 把共享文件夹中的全部图片复制到本机选定目录
  Future<void> _copyAll() async {
    if (_copyingAll) return;
    final loc = AppLocalizations.of(context);
    final destination = Platform.isAndroid
        ? await MediaStoreService.pickDestinationDir()
        : await DirectoryPickerService.pickDirectory();
    if (destination == null || !mounted) return;

    setState(() => _copyingAll = true);
    try {
      // 尚未加载完时先补全元数据，确保复制的是整个文件夹而非当前一页
      final all = _items.length >= _total
          ? List<ImageItem>.of(_items)
          : await LanClientService.instance.fetchAllImages(
              widget.device,
              folderId: widget.folder.id,
            );
      if (!mounted) return;
      if (all == null || all.isEmpty) {
        _showSnack(loc.copyFailed);
        return;
      }

      final progress = ValueNotifier<(int, int)>((0, all.length));
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            content: ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (context, value, _) {
                final (done, total) = value;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: total == 0 ? null : done / total,
                    ),
                    const SizedBox(height: 12),
                    Text(loc.copyingFiles(done, total)),
                  ],
                );
              },
            ),
          ),
        ),
      );

      var failed = 0;
      if (Platform.isAndroid) {
        // SAF 只接受本地文件：先全部写入临时目录，再一次性交给系统复制
        Directory? tempDir;
        final paths = <String>[];
        try {
          final root = await getTemporaryDirectory();
          tempDir = await Directory(
            '${root.path}${Platform.pathSeparator}'
            'frame_flow_copy_${DateTime.now().microsecondsSinceEpoch}',
          ).create(recursive: true);
          for (var i = 0; i < all.length; i++) {
            final item = all[i];
            final url = item.remoteUrl;
            final bytes = url == null
                ? null
                : await LanClientService.instance.fetchBytes(url);
            if (bytes == null) {
              failed++;
            } else {
              final file = File(
                '${tempDir.path}${Platform.pathSeparator}'
                '${_fileNameFor(item, i)}',
              );
              await file.writeAsBytes(bytes, flush: true);
              paths.add(file.path);
            }
            progress.value = (i + 1, all.length);
          }
          if (paths.isNotEmpty &&
              !await MediaStoreService.copyFiles(destination, paths)) {
            failed += paths.length;
          }
        } catch (_) {
          failed = all.length;
        } finally {
          try {
            await tempDir?.delete(recursive: true);
          } catch (_) {}
        }
      } else {
        for (var i = 0; i < all.length; i++) {
          final item = all[i];
          final url = item.remoteUrl;
          try {
            final bytes = url == null
                ? null
                : await LanClientService.instance.fetchBytes(url);
            if (bytes == null) {
              failed++;
            } else {
              await File(
                '$destination${Platform.pathSeparator}${_fileNameFor(item, i)}',
              ).writeAsBytes(bytes, flush: true);
            }
          } catch (_) {
            failed++;
          }
          progress.value = (i + 1, all.length);
        }
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showSnack(failed == 0 ? loc.copiedAllTo : loc.copyFailed);
    } finally {
      if (mounted) setState(() => _copyingAll = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 播放远端文件夹：先把该文件夹的完整元数据取回，再交给播放页
  Future<void> _startPlayback(int index) async {
    if (_startingPlayback) return;
    setState(() {
      _startingPlayback = true;
      _selectedIndex = null;
    });
    try {
      final all = <ImageItem>[..._items];
      var offset = all.length;
      while (offset < _total) {
        // 沿用当前排序参数，保证播放列表与浏览顺序一致
        final page = await _fetchPage(offset: offset, limit: 500);
        if (page == null || page.items.isEmpty) break;
        all.addAll(page.items);
        if (page.nextOffset <= offset) break;
        offset = page.nextOffset;
      }
      if (!mounted) return;
      if (all.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).lanLoadFailed),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final targetKey = index >= 0 && index < all.length
          ? all[index].key
          : null;
      final slide = Provider.of<SlideProvider>(context, listen: false);
      // 从瀑布流进入：沿用当前排序，不套用设置页的播放顺序
      slide.setImages(all, followListOrder: true);
      if (targetKey != null) {
        final target = slide.images.indexWhere((item) => item.key == targetKey);
        slide.goToImage(target < 0 ? 0 : target);
      }
      slide.startPlay();
      if (mounted) openPlayerScreen(context);
    } finally {
      if (mounted) setState(() => _startingPlayback = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        // 移动端让文件夹名称紧跟返回按钮，节省横向空间
        titleSpacing: _isMobile ? 0 : null,
        title: Text(widget.folder.name),
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
        actions: [
          if (_items.isNotEmpty) ...[
            IconButton(
              tooltip: loc.copyAllTo,
              icon: _copyingAll
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.content_copy, color: Colors.greenAccent),
              onPressed: _copyingAll ? null : _copyAll,
            ),
            _buildSortMenu(loc),
          ],
        ],
      ),
      body: _buildBody(loc),
    );
  }

  Widget _buildBody(AppLocalizations loc) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return _FailedView(message: loc.lanLoadFailed, onRetry: _loadFirstPage);
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          loc.noImagesInFolder,
          style: const TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    return MasonryImageGrid(
      items: _items,
      selectedIndex: _selectedIndex,
      onTap: (index) {
        // 桌面端悬停即可看到复制按钮，点按直接进入播放；
        // 手机端没有悬停，第一次点按先显示复制按钮，再次点按才进入播放
        if (!_isMobile || _selectedIndex == index) {
          _startPlayback(index);
        } else {
          setState(() => _selectedIndex = index);
        }
      },
      onLongPress: _startPlayback,
      onDelete: (index) {
        _copyImage(_items[index]);
        if (mounted) setState(() => _selectedIndex = null);
      },
      singleActionOverlay: true,
      singleActionIcon: Icons.content_copy,
      singleActionColor: Colors.greenAccent,
      singleActionTooltip: loc.copyTo,
      hasMore: _items.length < _total,
      onLoadMore: _loadMore,
    );
  }
}

class _FailedView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _FailedView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: Text(loc.lanRetry)),
        ],
      ),
    );
  }
}

/// 共享文件夹瀑布流的排序方式（菜单项）
enum _RemoteSortAction {
  nameAsc,
  nameDesc,
  timeNewest,
  timeOldest,
  sizeLargest,
  sizeSmallest,
  random,
}
