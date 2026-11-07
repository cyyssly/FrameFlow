import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:frame_flow/main.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/models/image_library.dart';
import 'package:frame_flow/models/lan_models.dart';
import 'package:frame_flow/providers/lan_provider.dart';
import 'package:frame_flow/screens/excluded_images_screen.dart';
import 'package:frame_flow/screens/folder_images_screen.dart';
import 'package:frame_flow/screens/player_screen.dart';
import 'package:frame_flow/screens/remote_browser_screen.dart';
import 'package:frame_flow/services/directory_picker_service.dart';
import 'package:frame_flow/services/image_scan_service.dart';
import 'package:frame_flow/services/media_store_service.dart';
import 'package:frame_flow/l10n/app_localizations.dart';

class FolderSelectionScreen extends StatefulWidget {
  const FolderSelectionScreen({super.key});

  @override
  State<FolderSelectionScreen> createState() => _FolderSelectionScreenState();
}

/// 归并后的本地文件夹条目。
///
/// 移动端把所有同名的相册路径合并成一个条目统一管理；桌面端每个路径
/// 各自成为一个条目。
class _LocalFolderGroup {
  /// 展示名称：移动端为最后一级目录名，桌面端为完整路径
  final String name;

  /// 该条目实际包含的文件夹路径
  final List<String> paths;

  const _LocalFolderGroup(this.name, this.paths);

  /// 播放/移除进行中状态的键（路径组合后保持稳定）
  String get key => 'local:${paths.join('|')}';
}

/// “添加共享源”对话框的返回值：选择已有设备，或手动添加（device 为 null）
class _ShareSourcePick {
  final LanDevice? device;

  const _ShareSourcePick(this.device);
}

class _FolderSelectionScreenState extends State<FolderSelectionScreen>
    with RouteAware {
  bool _isScanning = false;

  // 缓存每个文件夹的统计信息
  final Map<String, Map<String, int>> _folderStats = {};
  // 跟踪正在计数的文件夹
  final Set<String> _scanningFolders = {};

  /// 正在为该文件夹准备播放（扫描中），用于禁用其播放按钮并显示进度
  final Set<String> _playingFolders = {};

  /// 是否正在添加文件夹（含原生对话框弹出期间），用于防止重复触发
  bool _isAddingFolder = false;

  /// 是否正在打开“添加共享源”流程
  bool _isAddingShareSource = false;

  /// 正在准备播放的共享文件夹（ref.key）
  final Set<String> _playingShared = {};

  /// 正在重连的共享文件夹（ref.key）
  final Set<String> _refreshingShared = {};

  /// 当前扫描的中止标记。
  ///
  /// 每次扫描都新建一个标记，中止只会作用于对应的那一次扫描；
  /// 中止后立刻重新扫描使用新标记，不会被旧标记影响。
  _ScanToken? _scanToken;

  Future<void> _addFolder() async {
    // 防止重复触发（例如快速双击“添加文件夹”按钮）并发打开原生对话框。
    // Windows 原生目录对话框不允许并发打开，否则会触发 Shell 访问冲突，
    // 导致进程直接退出（Dart 层无法捕获）。
    if (_isAddingFolder) return;
    _isAddingFolder = true;
    try {
      await _addFolderImpl();
    } finally {
      _isAddingFolder = false;
    }
  }

  Future<void> _addFolderImpl() async {
    if (Platform.isAndroid) {
      // Android 端使用 MediaStore 读取相册列表
      final hasPermission = await MediaStoreService.requestStoragePermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).needPermissionToRead),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final albums = await MediaStoreService.getImageAlbums();
      if (albums.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).msgNoAlbumsFound),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      // 弹出相册多选对话框
      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
      final currentFolderPaths = slideProvider.folderPaths.toSet();
      final selectedAlbums = await showDialog<List<AlbumInfo>>(
        context: context,
        builder: (context) {
          // 已选中的相册默认勾选
          final selected = <bool>[
            for (final album in albums) currentFolderPaths.contains(album.path),
          ];
          return AlertDialog(
            backgroundColor: const Color(0xFF16213e),
            title: Text(
              AppLocalizations.of(context).selectAlbumTitle,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            content: SizedBox(
              width: double.maxFinite,
              // 限制最大高度，确保相册列表可以滚动
              height: MediaQuery.of(context).size.height * 0.6,
              child: StatefulBuilder(
                builder: (context, setDialogState) => ListView.builder(
                  shrinkWrap: true,
                  itemCount: albums.length,
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    final isChecked = selected[index];
                    return CheckboxListTile(
                      value: isChecked,
                      onChanged: (value) {
                        setDialogState(() {
                          selected[index] = value ?? false;
                        });
                      },
                      activeColor: const Color(0xFFe94560),
                      checkColor: Colors.white,
                      secondary: _albumThumbnail(
                        thumbnailPath: album.thumbnailPath,
                        albumPath: album.path,
                      ),
                      title: Text(
                        album.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        AppLocalizations.of(
                          context,
                        ).imagesCount(album.imageCount),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  AppLocalizations.of(context).cancel,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              TextButton(
                onPressed: () {
                  final chosen = <AlbumInfo>[];
                  for (var i = 0; i < albums.length; i++) {
                    if (selected[i]) chosen.add(albums[i]);
                  }
                  Navigator.pop(context, chosen.isEmpty ? null : chosen);
                },
                child: Text(
                  AppLocalizations.of(context).confirm,
                  style: const TextStyle(
                    color: Color(0xFFe94560),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          );
        },
      );

      if (selectedAlbums != null && selectedAlbums.isNotEmpty) {
        if (!mounted) return;
        final slideProvider = Provider.of<SlideProvider>(
          context,
          listen: false,
        );
        final settingsProvider = Provider.of<SettingsProvider>(
          context,
          listen: false,
        );
        for (final album in selectedAlbums) {
          slideProvider.addFolderPath(album.path);
        }
        settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

        // 计算新添加相册的统计信息
        for (final album in selectedAlbums) {
          _countFolderImages(album.path);
        }
      }
    } else {
      // 桌面端使用原生目录选择对话框，支持一次选择多个文件夹
      //（带互斥保护，避免重复弹窗导致原生崩溃）
      final results = await DirectoryPickerService.pickDirectories();
      if (results.isNotEmpty) {
        if (!mounted) return;
        final slideProvider = Provider.of<SlideProvider>(
          context,
          listen: false,
        );
        final settingsProvider = Provider.of<SettingsProvider>(
          context,
          listen: false,
        );
        for (final path in results) {
          slideProvider.addFolderPath(path);
        }
        settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

        // 计算新添加文件夹的统计信息
        for (final path in results) {
          _countFolderImages(path);
        }
      }
    }
  }

  /// 显示媒体库管理弹层：切换 / 新建 / 重命名 / 删除
  void _showLibrarySheet(BuildContext context) {
    final loc = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF16213e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return Consumer<SettingsProvider>(
          builder: (context, settings, _) {
            final allLibs = settings.libraries;
            // 关闭「显示隐藏媒体库」时，隐藏库完全不出现
            final libs = settings.showHiddenLibraries
                ? allLibs
                : [
                    for (final lib in allLibs)
                      if (!lib.hidden) lib,
                  ];
            return SafeArea(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          const Icon(Icons.photo_library, color: Colors.white),
                          const SizedBox(width: 8),
                          Text(
                            loc.mediaLibraries,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (libs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            allLibs.isEmpty
                                ? loc.noLibrariesHint
                                : loc.hiddenLibrariesCollapsed,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        )
                      else
                        ...libs.map((lib) {
                          final isActive = lib.id == settings.activeLibraryId;
                          final tile = ListTile(
                            leading: Icon(
                              isActive
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color: isActive
                                  ? const Color(0xFF00b894)
                                  : Colors.white54,
                            ),
                            title: Text(
                              lib.name,
                              style: TextStyle(
                                color: isActive ? Colors.white : Colors.white70,
                                fontWeight: isActive
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            subtitle: Text(
                              loc.libraryItemCount(
                                lib.folderPaths.length,
                                lib.sharedFolderKeys.length,
                              ),
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _switchToLibrary(lib.id);
                            },
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(
                                Icons.more_vert,
                                color: Colors.white54,
                              ),
                              onSelected: (action) {
                                if (action == 'rename') {
                                  _renameLibrary(context, settings, lib);
                                } else if (action == 'hide') {
                                  _setLibraryHidden(lib);
                                } else if (action == 'delete') {
                                  _deleteLibrary(context, settings, lib);
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text(loc.renameLibrary),
                                ),
                                PopupMenuItem(
                                  value: 'hide',
                                  child: Text(
                                    lib.hidden
                                        ? loc.unhideLibrary
                                        : loc.hideLibrary,
                                  ),
                                ),
                                // 只剩一个库时禁止删除
                                if (allLibs.length > 1)
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(
                                      loc.deleteLibrary,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                          // 隐藏库在开启「显示隐藏媒体库」时以半透明展示
                          return lib.hidden
                              ? Opacity(opacity: 0.5, child: tile)
                              : tile;
                        }),
                      const Divider(color: Colors.white12),
                      TextButton.icon(
                        onPressed: () => _createLibrary(context, settings),
                        icon: const Icon(Icons.add),
                        label: Text(loc.newLibrary),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF00b894),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 切换到指定库：同步文件夹列表、清空旧图片并重新统计
  void _switchToLibrary(String id) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.activeLibraryId == id) return;
    settings.switchLibrary(id);
    _syncAfterLibraryChange();
  }

  /// 切换某个库的隐藏状态；若因此换了激活库，一并同步播放与统计
  void _setLibraryHidden(ImageLibrary lib) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final activeChanged = settings.setLibraryHidden(lib.id, !lib.hidden);
    if (activeChanged) _syncAfterLibraryChange();
  }

  /// 激活库变化后同步 SlideProvider 的文件夹，并刷新统计与共享源探测
  void _syncAfterLibraryChange() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slide = Provider.of<SlideProvider>(context, listen: false);
    slide.setFolderPaths(settings.lastFolderPaths);
    slide.setImages(const []);
    setState(_folderStats.clear);
    _refreshStats();
    _probeSharedDevices();
  }

  Future<void> _createLibrary(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    final loc = AppLocalizations.of(context);
    var text = '';
    final name = await showDialog<String>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: Text(loc.newLibrary),
        content: TextFormField(
          initialValue: '',
          autofocus: true,
          decoration: InputDecoration(hintText: loc.libraryNameHint),
          onChanged: (value) => text = value,
          onFieldSubmitted: (value) => Navigator.pop(dlgCtx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, text),
            child: Text(loc.confirm),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;

    settings.addLibrary(name);
    if (!context.mounted) return;
    _syncAfterLibraryChange();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(loc.pleaseAddFolder),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _renameLibrary(
    BuildContext context,
    SettingsProvider settings,
    ImageLibrary lib,
  ) async {
    final loc = AppLocalizations.of(context);
    var text = lib.name;
    final name = await showDialog<String>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: Text(loc.renameLibrary),
        content: TextFormField(
          initialValue: lib.name,
          autofocus: true,
          decoration: InputDecoration(hintText: loc.libraryNameHint),
          onChanged: (value) => text = value,
          onFieldSubmitted: (value) => Navigator.pop(dlgCtx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, text),
            child: Text(loc.confirm),
          ),
        ],
      ),
    );
    if (name != null) settings.renameLibrary(lib.id, name);
  }

  Future<void> _deleteLibrary(
    BuildContext context,
    SettingsProvider settings,
    ImageLibrary lib,
  ) async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        content: Text(loc.confirmDeleteLibrary),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: Text(
              loc.deleteLibrary,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final wasActive = settings.activeLibraryId == lib.id;
    settings.removeLibrary(lib.id);
    if (!wasActive || !context.mounted) return;
    _syncAfterLibraryChange();
  }

  /// 计算文件夹中的图片数量和子文件夹数量
  Future<void> _countFolderImages(String folderPath) async {
    if (_scanningFolders.contains(folderPath)) return;

    setState(() {
      _scanningFolders.add(folderPath);
    });

    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    try {
      const supportedExtensions = {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'};

      int imageCount = 0;
      int subfolderCount = 0;

      // 副标题显示的是可播放的文件数量，需要剔除已排除的图片
      final excluded = {
        for (final path in settingsProvider.excludedPaths)
          Platform.isWindows ? path.toLowerCase() : path,
      };
      bool isExcluded(String path) =>
          excluded.contains(Platform.isWindows ? path.toLowerCase() : path);

      if (Platform.isAndroid) {
        // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
        final images = await MediaStoreService.getFolderImages(folderPath);
        for (final item in images) {
          if (isExcluded(item.path)) continue;
          final dotIndex = item.path.lastIndexOf('.');
          if (dotIndex != -1) {
            final ext = item.path.toLowerCase().substring(dotIndex + 1);
            if (supportedExtensions.contains(ext)) {
              imageCount++;
            }
          }
        }
      } else if (settingsProvider.recursiveScan) {
        final dir = Directory(folderPath);
        await for (var entity in dir.list(recursive: true)) {
          if (entity is File) {
            if (isExcluded(entity.path)) continue;
            final dotIndex = entity.path.lastIndexOf('.');
            if (dotIndex != -1) {
              final ext = entity.path.toLowerCase().substring(dotIndex + 1);
              if (supportedExtensions.contains(ext)) {
                imageCount++;
              }
            }
          } else if (entity is Directory) {
            subfolderCount++;
          }
        }
      } else {
        final dir = Directory(folderPath);
        final entities = await dir.list().toList();
        for (var entity in entities) {
          if (entity is File) {
            if (isExcluded(entity.path)) continue;
            final dotIndex = entity.path.lastIndexOf('.');
            if (dotIndex != -1) {
              final ext = entity.path.toLowerCase().substring(dotIndex + 1);
              if (supportedExtensions.contains(ext)) {
                imageCount++;
              }
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _folderStats[folderPath] = {
          'imageCount': imageCount,
          'subfolderCount': subfolderCount,
        };
        _scanningFolders.remove(folderPath);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _folderStats[folderPath] = {'imageCount': 0, 'subfolderCount': 0};
        _scanningFolders.remove(folderPath);
      });
    }
  }

  /// 重新统计所有已选文件夹与「已排除的文件」的数量。
  ///
  /// 文件可能在应用外被移走或删除，缓存与设置里的路径都会过期，
  /// 因此每次进入本页（含从子页面返回）都要重新计算一遍。
  Future<void> _refreshStats() async {
    if (!mounted) return;
    // 先剔除磁盘上已不存在的文件夹（相册在应用外被删除）
    await _pruneMissingFolders();
    if (!mounted) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    setState(() {
      _folderStats.clear();
    });
    for (final path in slideProvider.folderPaths) {
      _countFolderImages(path);
    }
  }

  /// 移除磁盘上已经不存在的文件夹。
  ///
  /// 与「存在但图片数量为 0」区分开：只要目录仍在就保留，由用户自行决定是否移除；
  /// 目录已被删除（例如在系统文件管理器里删掉相册）时直接从列表与设置中移除。
  Future<void> _pruneMissingFolders() async {
    if (!mounted) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    if (slideProvider.folderPaths.isEmpty) return;

    final missing = <String>[];
    for (final path in List<String>.of(slideProvider.folderPaths)) {
      bool exists;
      try {
        exists = await Directory(path).exists();
      } catch (_) {
        // 无法判断时（如权限受限）保留，避免误删用户的文件夹
        exists = true;
      }
      if (!exists) missing.add(path);
    }
    if (missing.isEmpty || !mounted) return;

    for (final path in missing) {
      slideProvider.removeFolderPath(path);
      settingsProvider.setLastFolderPaths(slideProvider.folderPaths);
    }
    setState(() {
      for (final path in missing) {
        _folderStats.remove(path);
        _scanningFolders.remove(path);
      }
    });
  }

  /// 提取路径的最后一级目录名（兼容 / 和 \ 分隔符）
  String _getLastPathSegment(String path) {
    // 去掉末尾的分隔符
    var clean = path;
    while (clean.endsWith('/') || clean.endsWith('\\')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final lastIndex = clean.lastIndexOf(RegExp(r'[/\\]'));
    return lastIndex >= 0 ? clean.substring(lastIndex + 1) : clean;
  }

  /// 规范化目录路径，避免同一目录因末尾分隔符差异被拆成两组
  String _normalizeFolderPath(String path) {
    if (path.isEmpty) return path;
    var clean = path;
    while (clean.length > 1 && (clean.endsWith('/') || clean.endsWith('\\'))) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  /// 把本地文件夹按条目归并：
  /// - 移动端：所有同名的相册归为一个条目
  /// - 桌面端：一个路径一个条目
  List<_LocalFolderGroup> _groupLocalPaths(List<String> paths) {
    if (!Platform.isAndroid) {
      return [
        for (final path in paths) _LocalFolderGroup(path, [path]),
      ];
    }
    final byName = <String, List<String>>{};
    for (final path in paths) {
      byName.putIfAbsent(_getLastPathSegment(path), () => []).add(path);
    }
    return [
      for (final entry in byName.entries)
        _LocalFolderGroup(entry.key, entry.value),
    ];
  }

  /// 构建文件夹统计信息的 widget（同名条目会把各路径的数量相加）
  Widget _buildFolderStats(_LocalFolderGroup group) {
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (group.paths.any(_scanningFolders.contains)) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    var hasStats = false;
    var imageCount = 0;
    var subfolderCount = 0;
    for (final path in group.paths) {
      final stats = _folderStats[path];
      if (stats == null) continue;
      hasStats = true;
      imageCount += stats['imageCount'] ?? 0;
      subfolderCount += stats['subfolderCount'] ?? 0;
    }
    if (!hasStats) {
      return const SizedBox.shrink();
    }

    String countText;
    if (settingsProvider.recursiveScan && subfolderCount > 0) {
      countText = AppLocalizations.of(
        context,
      ).folderContentCount(subfolderCount, imageCount);
    } else {
      countText = AppLocalizations.of(context).filesCount(imageCount);
    }

    return Text(
      countText,
      style: const TextStyle(fontSize: 12, color: Colors.grey),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  void _removeFolderGroup(_LocalFolderGroup group) {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    for (final path in group.paths) {
      slideProvider.removeFolderPath(path);
    }
    settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

    // 清除缓存的统计信息
    setState(() {
      for (final path in group.paths) {
        _folderStats.remove(path);
        _scanningFolders.remove(path);
      }
    });
  }

  /// 直接播放某个已选文件夹：以该文件夹为播放范围进入幻灯。
  ///
  /// 移动端同名文件夹归并为一个条目，这里会合并所有路径的图片并去重。
  Future<void> _playFolderGroup(_LocalFolderGroup group) async {
    // 任一扫描进行中时忽略重复触发，避免并发扫描 / 打开多个播放页
    if (_isScanning) return;
    final groupKey = group.key;
    if (_playingFolders.contains(groupKey)) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    setState(() {
      _playingFolders.add(groupKey);
    });

    // 点击播放立即进入播放页：扫描在后台进行，播放页中央显示扫描提示
    final token = _beginPlaybackScan(
      slideProvider,
      AppLocalizations.of(context).scanning,
    );
    try {
      final unique = <String, ImageItem>{};
      for (final path in group.paths) {
        for (final image in await _scanFolder(path, settingsProvider)) {
          unique.putIfAbsent(image.key, () => image);
        }
        if (token.aborted) return;
      }
      final images = unique.values.toList();
      if (!mounted || token.aborted) return;
      if (images.isEmpty) {
        _leavePlayerAndWarn(AppLocalizations.of(context).msgNoImages);
        return;
      }

      // 与瀑布流页一致：范围限定为该文件夹，顺序按「播放顺序」设置
      slideProvider.setImages(images, playOrder: settingsProvider.playOrder);
      slideProvider.sortByPlayOrder(settingsProvider.playOrder);
      slideProvider.goToImage(0);
      slideProvider.startPlay();
    } finally {
      if (mounted) {
        setState(() {
          _playingFolders.remove(groupKey);
        });
      }
      if (!token.aborted) _finishScan(slideProvider);
    }
  }

  /// 打开“添加共享源”：先选择设备，再进入该设备的共享文件夹列表勾选
  Future<void> _addShareSource() async {
    if (_isAddingShareSource) return;
    _isAddingShareSource = true;
    try {
      final lan = Provider.of<LanProvider>(context, listen: false);
      await lan.refresh();
      if (!mounted) return;

      final pick = await showDialog<_ShareSourcePick>(
        context: context,
        builder: (dialogContext) {
          final loc = AppLocalizations.of(dialogContext);
          return AlertDialog(
            backgroundColor: const Color(0xFF16213e),
            title: Text(
              loc.addShareSource,
              style: const TextStyle(fontSize: 18),
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(dialogContext).size.height * 0.6,
              child: Consumer<LanProvider>(
                builder: (context, lan, _) => ListView(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.add_link),
                      title: Text(loc.lanManualAdd),
                      subtitle: Text(loc.lanManualHint),
                      onTap: () => Navigator.pop(
                        dialogContext,
                        const _ShareSourcePick(null),
                      ),
                    ),
                    const Divider(height: 1),
                    if (lan.devices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            loc.lanNoDevices,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    else
                      for (final device in lan.devices)
                        ListTile(
                          leading: const Icon(
                            Icons.devices,
                            color: Color(0xFF00b894),
                          ),
                          title: Text(device.name),
                          subtitle: Text(
                            '${device.address} · '
                            '${loc.lanSharedFoldersCount(device.folderCount)}',
                          ),
                          onTap: () => Navigator.pop(
                            dialogContext,
                            _ShareSourcePick(device),
                          ),
                        ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(
                  AppLocalizations.of(dialogContext).cancel,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          );
        },
      );
      if (pick == null || !mounted) return;

      var device = pick.device;
      if (device == null) {
        final input = await _promptManualAddress();
        if (input == null || !mounted) return;
        device = await lan.addManualDevice(input);
        if (device == null) {
          if (!mounted) return;
          final loc = AppLocalizations.of(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                lan.error == LanError.selfDevice
                    ? loc.lanSelfDevice
                    : loc.lanInvalidAddress,
              ),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              RemoteFoldersScreen(device: device!, selectMode: true),
        ),
      );
    } finally {
      _isAddingShareSource = false;
    }
  }

  Future<String?> _promptManualAddress() async {
    final loc = AppLocalizations.of(context);
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: Text(loc.lanManualAdd),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: loc.lanManualHint),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(loc.lanAdd),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = input?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// 播放单个共享文件夹
  Future<void> _playSharedFolder(SharedFolderRef ref) async {
    // 任一扫描进行中时忽略重复触发，避免并发读取 / 打开多个播放页
    if (_isScanning) return;
    if (!_playingShared.add(ref.key)) return;
    setState(() {});
    final lan = Provider.of<LanProvider>(context, listen: false);
    final slide = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 点击播放立即进入播放页，读取进度显示在播放页中央
    final token = _beginPlaybackScan(
      slide,
      AppLocalizations.of(context).readingSharedFolder(ref.folderName),
    );
    try {
      final images = await lan.loadSharedFolderImages(ref);
      if (!mounted || token.aborted) return;
      if (images == null) {
        _leavePlayerAndWarn(AppLocalizations.of(context).lanLoadFailed);
        return;
      }
      if (images.isEmpty) {
        _leavePlayerAndWarn(
          AppLocalizations.of(context).noImagesInFolder,
          backgroundColor: Colors.orange,
        );
        return;
      }
      slide.setImages(images, playOrder: settings.playOrder);
      slide.sortByPlayOrder(settings.playOrder);
      slide.goToImage(0);
      slide.startPlay();
    } finally {
      if (mounted) {
        setState(() => _playingShared.remove(ref.key));
      }
      if (!token.aborted) _finishScan(slide);
    }
  }

  /// 播放全部本地文件夹
  Future<void> _playLocalSection() async {
    if (_isScanning) return;
    final slide = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (slide.folderPaths.isEmpty) return;

    // 点击播放立即进入播放页：扫描在后台进行，播放页中央显示扫描提示
    final token = _beginPlaybackScan(
      slide,
      AppLocalizations.of(context).scanning,
    );
    try {
      final unique = <String, ImageItem>{};
      for (final path in slide.folderPaths) {
        for (final image in await _scanFolder(path, settings)) {
          unique[image.key] = image;
        }
        if (token.aborted) return;
      }
      if (!mounted || token.aborted) return;
      final images = unique.values.toList();
      if (images.isEmpty) {
        _leavePlayerAndWarn(AppLocalizations.of(context).msgNoImages);
        return;
      }
      slide.setImages(images, playOrder: settings.playOrder);
      slide.sortByPlayOrder(settings.playOrder);
      slide.goToStartPosition(settings.playOrder);
      slide.startPlay();
    } finally {
      if (!token.aborted) _finishScan(slide);
    }
  }

  /// 播放全部共享文件夹（离线设备自动跳过）
  Future<void> _playSharedSection() async {
    if (_isScanning) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final refs = settings.activeLibrarySharedFolders;
    if (refs.isEmpty) return;
    await _playSharedFolders(refs);
  }

  Future<void> _playSharedFolders(List<SharedFolderRef> refs) async {
    if (_isScanning || refs.isEmpty) return;
    final lan = Provider.of<LanProvider>(context, listen: false);
    final slide = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // 点击播放立即进入播放页：读取进度显示在播放页中央
    final token = _beginPlaybackScan(
      slide,
      AppLocalizations.of(context).scanning,
    );
    try {
      await lan.probeSharedDevices(refs);
      if (token.aborted) return;
      final unique = <String, ImageItem>{};
      for (final ref in refs) {
        if (!mounted || token.aborted) return;
        if (!lan.isSharedFolderReachable(ref)) continue;
        slide.setScanning(
          true,
          statusText: AppLocalizations.of(
            context,
          ).readingSharedFolder(ref.folderName),
        );
        final images = await lan.loadSharedFolderImages(ref);
        if (token.aborted) return;
        if (images == null) continue;
        for (final image in images) {
          unique[image.key] = image;
        }
      }
      if (!mounted || token.aborted) return;
      if (unique.isEmpty) {
        _leavePlayerAndWarn(AppLocalizations.of(context).lanLoadFailed);
        return;
      }
      final images = unique.values.toList();
      slide.setImages(images, playOrder: settings.playOrder);
      slide.sortByPlayOrder(settings.playOrder);
      slide.goToStartPosition(settings.playOrder);
      slide.startPlay();
    } finally {
      if (!token.aborted) _finishScan(slide);
    }
  }

  /// 重新连接单个共享文件夹
  Future<void> _refreshSharedFolder(SharedFolderRef ref) async {
    if (!_refreshingShared.add(ref.key)) return;
    setState(() {});
    try {
      final lan = Provider.of<LanProvider>(context, listen: false);
      final ok = await lan.refreshSharedFolder(ref);
      if (!mounted || ok) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).lanLoadFailed),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _refreshingShared.remove(ref.key));
      }
    }
  }

  /// 重新连接全部共享文件夹
  Future<void> _refreshAllSharedFolders() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final refs = settings.activeLibrarySharedFolders;
    if (refs.isEmpty) return;
    final lan = Provider.of<LanProvider>(context, listen: false);
    await lan.refreshSharedFolders(refs);
    if (!mounted) return;
    if (refs.every((ref) => !lan.isSharedFolderReachable(ref))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).lanLoadFailed),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// 打开共享文件夹的瀑布流浏览页
  void _openSharedImages(SharedFolderRef ref) {
    final lan = Provider.of<LanProvider>(context, listen: false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RemoteImagesScreen(
          device: lan.resolveDevice(ref),
          folder: RemoteFolder(
            id: ref.folderId,
            name: ref.folderName,
            imageCount: ref.imageCount,
          ),
        ),
      ),
    );
  }

  /// 构建“已排除文件”分组：按所在文件夹聚合，每个文件夹一行
  List<Widget> _buildExcludedSection(
    SettingsProvider settings, {
    required bool addTopDivider,
  }) {
    // 按父目录归组，并忽略应用外已被移走的文件
    final groups = <String, List<String>>{};
    final seen = <String>{};
    for (final path in settings.excludedPaths) {
      if (!File(path).existsSync()) continue;
      // 同一张图片可能因历史数据被重复记录，只统计一次
      if (!seen.add(path)) continue;
      final parent = _normalizeFolderPath(File(path).parent.path);
      // 手机端只按最后一级目录名归组：同名目录即使路径不同也视为同一目录，
      // 避免出现两行同名但内容不同的分组
      final key = Platform.isAndroid ? _getLastPathSegment(parent) : parent;
      groups.putIfAbsent(key, () => []).add(path);
    }
    if (groups.isEmpty) return const [];

    final entries = groups.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final allPaths = [for (final paths in groups.values) ...paths];
    final loc = AppLocalizations.of(context);
    return [
      if (addTopDivider) const Divider(height: 1, color: Colors.grey),
      _buildSectionHeader(
        title: loc.excludedFilesSection,
        actionsInline: true,
        actions: [
          _actionButton(
            tooltip: loc.restoreAll,
            icon: const Icon(Icons.undo, color: Colors.greenAccent),
            onPressed: () => _restoreExcludedGroup(allPaths),
          ),
        ],
      ),
      for (final entry in entries)
        _buildExcludedGroupTile(entry.key, entry.value),
    ];
  }

  /// 单个文件夹的已排除文件条目
  ///
  /// [folderName] 即界面显示的分组名称（手机端为目录名，桌面端为完整路径）。
  /// 与本地 / 共享文件夹共用 [_folderRow]，保证行高与垂直居中完全一致。
  Widget _buildExcludedGroupTile(String folderName, List<String> paths) {
    final loc = AppLocalizations.of(context);
    final firstPath = paths.first;
    return _folderRow(
      key: ValueKey('excluded-group-$folderName'),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: _ThumbnailImage(
            key: ValueKey('thumb-excluded-$firstPath'),
            thumbnailPath: firstPath,
            albumPath: firstPath,
          ),
        ),
      ),
      title: folderName,
      subtitle: Text(
        loc.filesCount(paths.length),
        style: const TextStyle(fontSize: 12, color: Colors.grey),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        _actionButton(
          tooltip: loc.restoreFiles,
          icon: const Icon(Icons.undo, color: Colors.greenAccent),
          onPressed: () => _restoreExcludedGroup(paths),
        ),
        _actionButton(
          tooltip: loc.deleteFiles,
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          onPressed: () => _deleteExcludedGroup(paths),
        ),
      ],
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                ExcludedImagesScreen(folderName: folderName, paths: paths),
          ),
        );
      },
    );
  }

  /// 恢复某个文件夹下全部已排除文件
  void _restoreExcludedGroup(List<String> paths) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPaths(paths);
  }

  /// 删除某个文件夹下全部已排除文件（移入回收站）
  Future<void> _deleteExcludedGroup(List<String> paths) async {
    final loc = AppLocalizations.of(context);
    final ok = await MediaStoreService.deleteToTrash(paths);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.deleteFailed), backgroundColor: Colors.red),
      );
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPaths(paths);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(loc.deletedAllToTrash)));
  }

  Future<void> _scanImages() async {
    // 扫描进行中忽略重复触发（连按 Enter / 连续点击）
    if (_isScanning) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    final lanProvider = Provider.of<LanProvider>(context, listen: false);
    final loc = AppLocalizations.of(context);
    final sharedRefs = settingsProvider.activeLibrarySharedFolders;

    if (slideProvider.folderPaths.isEmpty && sharedRefs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.msgAddFolderFirst),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // 点击播放立即进入播放页：扫描在后台进行，播放页中央显示扫描提示
    final token = _beginPlaybackScan(slideProvider, loc.scanning);

    try {
      // 使用 Map 进行去重
      final uniqueImages = <String, ImageItem>{};

      // 逐个扫描本地文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final images = await _scanFolder(folderPath, settingsProvider);
        if (token.aborted) return;
        for (final image in images) {
          uniqueImages[image.key] = image;
        }
      }

      // 继续读取共享文件夹（离线设备自动跳过）
      if (sharedRefs.isNotEmpty) {
        await lanProvider.probeSharedDevices(sharedRefs);
        if (token.aborted) return;
        for (final ref in sharedRefs) {
          if (!mounted || token.aborted) return;
          if (!lanProvider.isSharedFolderReachable(ref)) continue;
          slideProvider.setScanning(
            true,
            statusText: AppLocalizations.of(
              context,
            ).readingSharedFolder(ref.folderName),
          );
          final images = await lanProvider.loadSharedFolderImages(ref);
          if (token.aborted) return;
          if (images == null) continue;
          for (final image in images) {
            uniqueImages[image.key] = image;
          }
        }
        if (!mounted || token.aborted) return;
        slideProvider.setScanning(true, statusText: loc.scanning);
      }

      final allImages = uniqueImages.values.toList();
      if (allImages.isEmpty) {
        _leavePlayerAndWarn(loc.msgNoImages);
        return;
      }

      // 与主页「开始播放」一致：全量排序后一次写入，从头开始播放
      slideProvider.setImages(allImages, playOrder: settingsProvider.playOrder);
      slideProvider.sortByPlayOrder(settingsProvider.playOrder);
      slideProvider.goToStartPosition(settingsProvider.playOrder);
      slideProvider.startPlay();
    } catch (e) {
      if (!mounted) return;
      _leavePlayerAndWarn(AppLocalizations.of(context).msgScanFailed(e));
    } finally {
      // 扫描被中止时状态已由 _abortScan 重置，这里跳过
      if (!token.aborted) {
        _finishScan(slideProvider);
      }
    }
  }

  /// 开始一次「扫描后播放」。
  ///
  /// 点击播放后立即进入播放页：扫描在后台进行，扫描/读取提示显示在
  /// 播放页中央。返回本次扫描的中止标记，供扫描流程检查是否已被中止。
  _ScanToken _beginPlaybackScan(SlideProvider slide, String statusText) {
    final token = _ScanToken();
    _scanToken = token;
    setState(() => _isScanning = true);

    // 清空上一次的播放列表，避免播放页先用旧图片显示/播放
    slide.stopPlay();
    slide.setImages(const []);
    slide.setScanning(true, statusText: statusText);

    // 不等待：播放页关闭（ESC）时中止本次扫描
    unawaited(openPlayerScreen(context).then((_) => _abortScan(slide, token)));
    return token;
  }

  /// 播放页在扫描结束前被关闭：中止本次扫描，结果作废。
  void _abortScan(SlideProvider slide, _ScanToken token) {
    if (!identical(_scanToken, token)) return;
    if (!_isScanning) return;
    token.aborted = true;
    slide.setScanning(false);
    if (mounted) {
      setState(() => _isScanning = false);
    } else {
      _isScanning = false;
    }
  }

  /// 扫描正常结束（未被中止）时收尾：关闭扫描提示并解除按钮禁用。
  void _finishScan(SlideProvider slide) {
    slide.setScanning(false);
    if (mounted) {
      setState(() => _isScanning = false);
    } else {
      _isScanning = false;
    }
  }

  /// 扫描没有得到可播放的图片时，先退回本页再提示，
  /// 避免提示被刚刚打开的播放页遮挡。
  void _leavePlayerAndWarn(
    String message, {
    Color backgroundColor = Colors.red,
  }) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<List<ImageItem>> _scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) => ImageScanService.scanFolder(folderPath, settings);

  bool _previousRecursiveScan = false;

  /// 断线共享文件夹的自动重连定时器与已尝试次数
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    // 页面初始化时，重新统计已有的文件夹与已排除文件
    Future.microtask(() {
      if (!mounted) return;
      final settingsProvider = Provider.of<SettingsProvider>(
        context,
        listen: false,
      );
      _previousRecursiveScan = settingsProvider.recursiveScan;
      _refreshStats();
      _probeSharedDevices();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅路由事件：从子页面返回本页时（didPopNext）需要重新统计
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
    // 当递归扫描设置变化时，重新计算所有文件夹的统计信息
    final settingsProvider = Provider.of<SettingsProvider>(context);
    if (_previousRecursiveScan != settingsProvider.recursiveScan) {
      _previousRecursiveScan = settingsProvider.recursiveScan;
      _refreshStats();
    }
  }

  /// 从子页面（已排除的文件 / 文件夹图片 / 播放页）返回本页时，
  /// 文件可能已被移走或删除，重新统计一次。
  ///
  /// 延后到当前帧结束再执行，避免在路由回调里直接触发 setState。
  @override
  void didPopNext() {
    Future.microtask(() {
      if (!mounted) return;
      _refreshStats();
      _probeSharedDevices();
    });
  }

  /// 探测已添加的共享源是否在线，用于决定文件夹条目的灰态与封面
  Future<void> _probeSharedDevices() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final refs = List<SharedFolderRef>.of(settings.activeLibrarySharedFolders);
    await lan.probeSharedDevices(refs);
    if (!mounted) return;
    lan.loadSharedFolderCovers(refs);
    _startSharedReconnectCycle();
  }

  /// 启动一轮自动重连（页面每次进入/返回时重新计时）
  void _startSharedReconnectCycle() {
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _attemptSharedReconnect();
  }

  /// 对离线共享文件夹按 2s / 5s / 10s 退避重试，最多 3 次。
  ///
  /// 重连成功（设备恢复在线）后下一轮会因没有离线项而自然停止。
  void _attemptSharedReconnect() {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final offline = settings.activeLibrarySharedFolders
        .where((ref) => !lan.isSharedFolderReachable(ref))
        .toList();
    if (offline.isEmpty) {
      _reconnectAttempt = 0;
      return;
    }
    if (_reconnectAttempt >= 3) return;

    const delays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ];
    final delay = delays[_reconnectAttempt];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () async {
      if (!mounted) return;
      await lan.probeSharedDevices(offline);
      if (!mounted) return;
      // 静默刷新，不弹失败提示，避免自动重试打扰用户
      await lan.refreshSharedFolders(offline);
      if (!mounted) return;
      _attemptSharedReconnect();
    });
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    appRouteObserver.unsubscribe(this);
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    super.dispose();
  }

  /// 键盘快捷键：ESC 返回主界面
  ///
  /// [HardwareKeyboard] 会无条件调用所有已注册的 handler，因此这里必须确认本页
  /// 位于最上层：若本页之上还有对话框（如相册选择弹窗），该弹窗才是当前路由，
  /// 此时不响应，避免一次按键既关闭弹窗又退出本页。
  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // 扫描进行中重复按 Enter 直接忽略，避免重复扫描
      if (_isScanning) return true;
      unawaited(_scanImages());
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        // 移动端列表里是相册，标题也统一为“选择相册”
        title: Consumer<SettingsProvider>(
          builder: (context, settings, _) {
            final lib = settings.activeLibrary;
            final defaultTitle = Platform.isAndroid
                ? loc.selectAlbumTitle
                : loc.selectFolderTitle;
            return Text(
              lib == null ? defaultTitle : '$defaultTitle · ${lib.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        actions: [
          IconButton(
            tooltip: loc.activeLibraryHint,
            icon: const Icon(Icons.photo_library),
            onPressed: () => _showLibrarySheet(context),
          ),
        ],
      ),
      body: Consumer2<SlideProvider, SettingsProvider>(
        builder: (context, slideProvider, settingsProvider, child) {
          final lan = Provider.of<LanProvider>(context);
          final localPaths = slideProvider.folderPaths;
          // 移动端同名文件夹归并为一个条目管理
          final localGroups = _groupLocalPaths(localPaths);
          final sharedFolders = settingsProvider.activeLibrarySharedFolders;
          // 有任一共享文件夹离线时，标题栏只提供重连入口
          final anySharedOffline = sharedFolders.any(
            (ref) => !lan.isSharedFolderReachable(ref),
          );
          return Padding(
            // 手机端横向空间紧张，缩小页面左右边距
            padding: EdgeInsets.symmetric(
              horizontal: Platform.isAndroid ? 8 : 16,
              vertical: 16,
            ),
            child: Column(
              children: [
                // 已选文件夹列表：本地 / 共享分类展示
                Expanded(
                  child: ListView(
                    children: [
                      if (localPaths.isNotEmpty) ...[
                        _buildSectionHeader(
                          title: loc.localFoldersSection,
                          actionsInline: true,
                          actions: [
                            _actionButton(
                              tooltip: loc.playLocalFolders,
                              icon: const Icon(
                                Icons.play_circle_outline,
                                color: Colors.green,
                              ),
                              onPressed: _isScanning ? null : _playLocalSection,
                            ),
                          ],
                        ),
                        for (final group in localGroups)
                          _buildLocalFolderTile(group, settingsProvider, lan),
                      ],
                      if (localPaths.isNotEmpty && sharedFolders.isNotEmpty)
                        const Divider(height: 1, color: Colors.grey),
                      if (sharedFolders.isNotEmpty) ...[
                        _buildSectionHeader(
                          title: loc.sharedFoldersSection,
                          actionsInline: true,
                          actions: [
                            if (anySharedOffline)
                              _actionButton(
                                tooltip: loc.lanReconnectAll,
                                icon: const Icon(Icons.refresh),
                                onPressed: _refreshAllSharedFolders,
                              )
                            else
                              _actionButton(
                                tooltip: loc.playSharedFolders,
                                icon: const Icon(
                                  Icons.play_circle_outline,
                                  color: Colors.green,
                                ),
                                onPressed: _isScanning
                                    ? null
                                    : _playSharedSection,
                              ),
                          ],
                        ),
                        for (final ref in sharedFolders)
                          _buildSharedFolderTile(ref, lan),
                      ],
                      ..._buildExcludedSection(
                        settingsProvider,
                        addTopDivider:
                            localPaths.isNotEmpty || sharedFolders.isNotEmpty,
                      ),
                    ],
                  ),
                ),
                // 操作按钮
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: _buildAddFolderButton(loc)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildAddShareSourceButton(loc)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isScanning ? null : _scanImages,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00b894),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 4,
                      shadowColor: const Color(
                        0xFF00b894,
                      ).withValues(alpha: 0.4),
                    ),
                    child: _isScanning
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.play_circle, size: 24),
                              const SizedBox(width: 12),
                              Text(
                                loc.startPlay,
                                style: const TextStyle(fontSize: 18),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 统一的文件夹条目布局：固定 88dp 行高 + 内容垂直居中。
  ///
  /// [ListTile] 的标题/副标题按 Material 三行规格从顶部固定偏移排版，
  /// 内容不足三行时会明显偏上；这里改用 Row 自行布局，保证缩略图、
  /// 文本块与操作按钮始终在行内居中，三类条目的高度与对齐完全一致。
  Widget _folderRow({
    required Key key,
    required Widget leading,
    required String title,
    required Widget subtitle,
    required List<Widget> actions,
    Color? titleColor,
    VoidCallback? onTap,
  }) {
    return SizedBox(
      key: key,
      height: 88,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(
            left: Platform.isAndroid ? 8 : 16,
            right: Platform.isAndroid ? 0 : 4,
          ),
          child: Row(
            children: [
              leading,
              SizedBox(width: Platform.isAndroid ? 8 : 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 14, color: titleColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    subtitle,
                  ],
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }

  /// 行内操作按钮：移动端压缩内边距与占位宽度，桌面端保持默认尺寸
  Widget _actionButton({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
  }) {
    final compact = Platform.isAndroid;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: compact ? EdgeInsets.zero : null,
      constraints: compact
          ? const BoxConstraints.tightFor(width: 36, height: 40)
          : null,
      tooltip: tooltip,
      icon: icon,
      onPressed: onPressed,
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required List<Widget> actions,
    bool actionsInline = false,
  }) {
    final titleWidget = Text(
      title,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.bold,
        color: Colors.grey,
      ),
    );
    return Padding(
      // 右侧留出与 ListTile 内容相同的 4dp 边距，
      // 让标题栏按钮与下方文件夹行右侧按钮处在同一竖列
      padding: EdgeInsets.fromLTRB(4, 8, Platform.isAndroid ? 0 : 4, 0),
      // 有操作按钮时行高由按钮决定；没有按钮的标题（如“已排除文件”）
      // 需要补足同样的最小高度，保证各分组标题行高度一致
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: Platform.isAndroid ? 40 : 48),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (actionsInline) ...[
              titleWidget,
              ...actions,
            ] else ...[
              Expanded(child: titleWidget),
              ...actions,
            ],
          ],
        ),
      ),
    );
  }

  /// 本地文件夹条目：第 2 行统计信息，第 3 行显示本机终端名与 IP
  Widget _buildLocalFolderTile(
    _LocalFolderGroup group,
    SettingsProvider settings,
    LanProvider lan,
  ) {
    final ip = lan.localAddresses.isNotEmpty
        ? lan.localAddresses.first
        : '127.0.0.1';
    final primaryPath = group.paths.first;
    final groupKey = group.key;
    return _folderRow(
      // 使用稳定的 Key 绑定到文件夹路径，避免 ListView 按位置复用 State，
      // 导致缩略图组件残留上一个位置的图片
      key: ValueKey('folder-$groupKey'),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: _ThumbnailImage(
            // 排除列表变化时重建，避免沿用排除前缓存的封面
            key: ValueKey('thumb-$groupKey-${settings.excludedPaths.length}'),
            thumbnailPath: null,
            albumPath: primaryPath,
          ),
        ),
      ),
      title: group.name,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildFolderStats(group),
          const SizedBox(height: 2),
          Text(
            '${settings.deviceName} · $ip',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      // 播放：直接以该文件夹为范围进入幻灯；
      // 排除：把该文件夹移出播放列表（原「删除」按钮的动作）
      actions: [
        _actionButton(
          tooltip: AppLocalizations.of(context).playFolder,
          icon: _playingFolders.contains(groupKey)
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_circle_outline, color: Colors.green),
          onPressed: _playingFolders.contains(groupKey)
              ? null
              : () => _playFolderGroup(group),
        ),
        _actionButton(
          tooltip: AppLocalizations.of(context).removeFromManage,
          icon: const Icon(Icons.remove_circle_outline, color: Colors.orange),
          onPressed: () => _removeFolderGroup(group),
        ),
      ],
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FolderImagesScreen(
              folderPath: primaryPath,
              extraFolderPaths: group.paths.skip(1).toList(),
            ),
          ),
        );
      },
    );
  }

  /// 共享文件夹无封面或离线时显示的文件夹图标
  Widget _sharedFolderIcon(bool online) {
    return Icon(
      Icons.folder_shared,
      size: 30,
      color: online ? const Color(0xFF00b894) : Colors.grey,
    );
  }

  /// 共享文件夹条目：离线时整体灰显，播放按钮禁用，仍可排除与重连
  Widget _buildSharedFolderTile(SharedFolderRef ref, LanProvider lan) {
    final loc = AppLocalizations.of(context);
    final online = lan.isSharedFolderReachable(ref);
    final device = lan.deviceById(ref.deviceId);
    final deviceName = device?.name ?? ref.deviceName;
    final address = device?.address ?? ref.address;
    // 优先使用磁盘缓存的封面：离线或应用重启后仍能显示上次的缩略图
    final coverFile = lan.coverFileFor(ref.key);
    final coverUrl = lan.coverUrlFor(ref.key);
    return _folderRow(
      key: ValueKey('shared-${ref.key}'),
      // 固定与本地缩略图相同的占位宽度，保证两类条目的文字左边缘对齐
      leading: SizedBox(
        width: 56,
        height: 56,
        child: coverFile != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(coverFile),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      _sharedFolderIcon(online),
                ),
              )
            : coverUrl == null
            ? _sharedFolderIcon(online)
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  // 加载期间先显示文件夹图标，避免出现空白占位
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                        if (wasSynchronouslyLoaded || frame != null) {
                          return child;
                        }
                        return _sharedFolderIcon(online);
                      },
                  errorBuilder: (context, error, stackTrace) =>
                      _sharedFolderIcon(online),
                ),
              ),
      ),
      title: ref.folderName,
      titleColor: online ? Colors.white : Colors.grey,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            loc.filesCount(ref.imageCount),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '$deviceName · $address',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        // 在线时只显示播放，离线时只显示重连
        if (!online)
          _actionButton(
            tooltip: loc.lanReconnectFolder,
            icon: _refreshingShared.contains(ref.key)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: () => _refreshSharedFolder(ref),
          ),
        if (online)
          _actionButton(
            tooltip: loc.playFolder,
            icon: _playingShared.contains(ref.key)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_circle_outline, color: Colors.green),
            onPressed: _playingShared.contains(ref.key)
                ? null
                : () => _playSharedFolder(ref),
          ),
        _actionButton(
          tooltip: loc.removeFromManage,
          icon: const Icon(Icons.remove_circle_outline, color: Colors.orange),
          onPressed: () {
            Provider.of<SettingsProvider>(
              context,
              listen: false,
            ).removeSharedFolderFromActiveLibrary(ref.key);
          },
        ),
      ],
      onTap: online ? () => _openSharedImages(ref) : null,
    );
  }

  Widget _buildAddFolderButton(AppLocalizations loc) {
    return ElevatedButton(
      onPressed: _addFolder,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF0984e3),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 3,
        shadowColor: const Color(0xFF0984e3).withValues(alpha: 0.3),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.add, size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              loc.addFolder,
              style: const TextStyle(fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddShareSourceButton(AppLocalizations loc) {
    return ElevatedButton(
      onPressed: _addShareSource,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF00cec9),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 3,
        shadowColor: const Color(0xFF00cec9).withValues(alpha: 0.3),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.add_link, size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              loc.addShareSource,
              style: const TextStyle(fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 相册缩略图组件 - 从 MediaStore 或文件系统加载第一张图片作为缩略图
  Widget _albumThumbnail({
    required String? thumbnailPath,
    required String albumPath,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 48,
        height: 48,
        child: _ThumbnailImage(
          key: ValueKey('album-thumb-$albumPath-$thumbnailPath'),
          thumbnailPath: thumbnailPath,
          albumPath: albumPath,
        ),
      ),
    );
  }
}

/// 异步加载缩略图的 StatefulWidget
class _ThumbnailImage extends StatefulWidget {
  final String? thumbnailPath;
  final String albumPath;

  const _ThumbnailImage({
    super.key,
    required this.thumbnailPath,
    required this.albumPath,
  });

  @override
  State<_ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<_ThumbnailImage> {
  Uint8List? _imageBytes;
  bool _loading = true;

  /// 每次发起加载时递增，用于识别“过期结果”。
  /// 只要这个值变了，就说明当前请求已不再是该 State 的最新请求。
  int _requestId = 0;

  static const _supportedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
  };

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _ThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只要缩略图来源（缩略图路径或所属相册/文件夹路径）发生变化就要重新加载。
    // 否则 ListView 按位置复用 State 时，会残留上一个条目的缩略图，
    // 导致所有文件夹都显示成同一张被排除的图片。
    if (oldWidget.thumbnailPath != widget.thumbnailPath ||
        oldWidget.albumPath != widget.albumPath) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    final requestId = ++_requestId;
    final requestAlbumPath = widget.albumPath;
    final requestThumbnailPath = widget.thumbnailPath;
    final excludedPaths = Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).excludedPaths;

    setState(() {
      _loading = true;
      // 必须清空旧图：否则下面的“优先读取缩略图，失败再回退到目录首图”
      // 会因为 _imageBytes 非空而被跳过，直接把上一个文件夹的图片继续显示出来
      _imageBytes = null;
    });

    // 结果先写局部变量，只有确认请求仍然有效才提交到 State，
    // 避免为文件夹 A 发起的读取把文件夹 B 的缩略图覆盖掉
    Uint8List? bytes;

    try {
      // 优先使用原生端返回的 content:// URI 或文件路径
      if (requestThumbnailPath != null && requestThumbnailPath.isNotEmpty) {
        if (requestThumbnailPath.startsWith('content://')) {
          // 通过 MethodChannel 读取 content:// URI
          bytes = await MediaStoreService.readImageBytes(requestThumbnailPath);
        } else {
          // 直接读取文件路径
          final file = File(requestThumbnailPath);
          if (await file.exists()) {
            bytes = await file.readAsBytes();
          }
        }
      }

      // 如果缩略图加载失败，尝试从相册文件夹中找第一张图片
      bytes ??= await _readFirstImageBytes(requestAlbumPath, excludedPaths);
    } catch (_) {}

    // 如果在加载期间已发起了新的请求（widget 被复用指向其他文件夹），
    // 丢弃本次结果，同时把 _loading 交还给新请求，不能提前置为 false
    if (!mounted || requestId != _requestId) return;

    setState(() {
      _imageBytes = bytes;
      _loading = false;
    });
  }

  /// 取文件夹中的第一张图片字节，作为缩略图回退方案。
  ///
  /// 已排除的图片不能用作封面，否则用户排除首图后封面仍显示那张图。
  /// Android 上不能直接用 dart:io 枚举 scoped storage 路径——
  /// 那些路径对应用不可见，既读不到内容还要白白付出一次目录遍历，
  /// 因此改走 MediaStore 拿到真实路径后再通过原生读取字节。
  static Future<Uint8List?> _readFirstImageBytes(
    String folderPath,
    List<String> excludedPaths,
  ) async {
    final excluded = {
      for (final path in excludedPaths)
        Platform.isWindows ? path.toLowerCase() : path,
    };
    bool isExcluded(String path) =>
        excluded.contains(Platform.isWindows ? path.toLowerCase() : path);

    if (Platform.isAndroid) {
      final images = await MediaStoreService.getFolderImages(folderPath);
      for (final item in images) {
        if (isExcluded(item.path)) continue;
        final ext = item.path.split('.').last.toLowerCase();
        if (!_supportedExtensions.contains(ext)) continue;
        final data = await MediaStoreService.readImageBytes(item.path);
        if (data != null) return data;
      }
      return null;
    }

    final dir = Directory(folderPath);
    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File && !isExcluded(entity.path)) {
          final ext = entity.path.split('.').last.toLowerCase();
          if (_supportedExtensions.contains(ext)) {
            try {
              return await entity.readAsBytes();
            } catch (_) {}
          }
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: const Color(0xFF1a1a2e),
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFe94560),
            ),
          ),
        ),
      );
    }

    if (_imageBytes != null) {
      // 缩略图容器最大 56dp，按真实尺寸解码即可。
      // 不加 cacheWidth 时会把整张原图（动辄上千万像素）解码出来塞进 56dp 的框里，
      // 是列表滚动卡顿的主要原因。
      final cacheWidth = (56 * MediaQuery.of(context).devicePixelRatio * 2)
          .round();
      return Image.memory(
        _imageBytes!,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF1a1a2e),
      child: const Icon(
        Icons.photo_library,
        color: Colors.blueAccent,
        size: 24,
      ),
    );
  }
}

/// 一次扫描的中止标记。
///
/// 扫描过程中用户退出播放页时把它置为 [aborted]，
/// 扫描循环在下一个检查点返回（结果作废）。
class _ScanToken {
  bool aborted = false;
}
