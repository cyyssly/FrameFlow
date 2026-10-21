import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:frame_flow/l10n/app_localizations.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/models/lan_models.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/screens/player_screen.dart';
import 'package:frame_flow/services/fullscreen_service.dart';
import 'package:frame_flow/services/lan_client_service.dart';
import 'package:frame_flow/widgets/masonry_image_grid.dart';

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

  /// 顺序：点击切到按名称排序；已在名称模式时切换顺序/逆序
  void _onSortByNamePressed() {
    setState(() {
      if (_sortKey == 'name') {
        _nameAscending = !_nameAscending;
      } else {
        _sortKey = 'name';
        _nameAscending = true;
      }
    });
    _loadFirstPage();
  }

  /// 日期：默认最新在前，再次点击切换最旧在前
  void _onSortByTimePressed() {
    setState(() {
      if (_sortKey == 'time') {
        _newestFirst = !_newestFirst;
      } else {
        _sortKey = 'time';
        _newestFirst = true;
      }
    });
    _loadFirstPage();
  }

  /// 大小：默认最大在前，再次点击切换最小在前
  void _onSortBySizePressed() {
    setState(() {
      if (_sortKey == 'size') {
        _largestFirst = !_largestFirst;
      } else {
        _sortKey = 'size';
        _largestFirst = true;
      }
    });
    _loadFirstPage();
  }

  /// 随机：换一个种子后重新从第一页取，保证后续分页沿用同一顺序
  void _onSortRandomPressed() {
    setState(() {
      _sortKey = 'random';
      _randomSeed = DateTime.now().microsecondsSinceEpoch.toString();
    });
    _loadFirstPage();
  }

  /// 排序按钮；当前生效的排序方式用强调色标识
  Widget _buildSortButton({
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      color: active ? const Color(0xFFe94560) : Colors.white70,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  void _precache(List<ImageItem> items) {
    if (items.isEmpty) return;
    unawaited(MasonryImageGrid.precacheItems(items, context, concurrency: 4));
  }

  /// 播放远端文件夹：先把该文件夹的完整元数据取回，再交给播放页
  Future<void> _startPlayback(int index) async {
    if (_startingPlayback) return;
    setState(() => _startingPlayback = true);
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
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      slide.setImages(all);
      slide.sortByPlayOrder(settings.playOrder);
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
        title: Text(widget.folder.name),
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
        actions: [
          if (_items.isNotEmpty) ...[
            // 顺序/逆序
            _buildSortButton(
              icon: _nameAscending ? Icons.arrow_upward : Icons.arrow_downward,
              tooltip: _nameAscending ? loc.sortSequential : loc.sortReverse,
              active: _sortKey == 'name',
              onPressed: _onSortByNamePressed,
            ),
            // 最新/最旧
            _buildSortButton(
              icon: _newestFirst ? Icons.update : Icons.history,
              tooltip: _newestFirst ? loc.sortNewest : loc.sortOldest,
              active: _sortKey == 'time',
              onPressed: _onSortByTimePressed,
            ),
            // 最大/最小
            _buildSortButton(
              icon: _largestFirst ? Icons.south : Icons.north,
              tooltip: _largestFirst ? loc.sortLargest : loc.sortSmallest,
              active: _sortKey == 'size',
              onPressed: _onSortBySizePressed,
            ),
            // 随机
            _buildSortButton(
              icon: Icons.shuffle,
              tooltip: loc.sortRandom,
              active: _sortKey == 'random',
              onPressed: _onSortRandomPressed,
            ),
          ],
          if (_startingPlayback)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: loc.lanPlayRemote,
              icon: const Icon(Icons.play_circle_outline),
              onPressed: _items.isEmpty ? null : () => _startPlayback(0),
            ),
          IconButton(
            tooltip: loc.lanRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadFirstPage,
          ),
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
      selectedIndex: null,
      onTap: _startPlayback,
      onLongPress: _startPlayback,
      onDelete: (_) {},
      singleActionOverlay: true,
      showOverlay: false,
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
