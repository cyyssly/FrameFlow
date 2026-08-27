import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/providers/slide_provider.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/screens/excluded_images_screen.dart';
import 'package:slide_show/screens/folder_images_screen.dart';
import 'package:slide_show/services/media_store_service.dart';
import 'package:slide_show/l10n/app_localizations.dart';

class FolderSelectionScreen extends StatefulWidget {
  const FolderSelectionScreen({super.key});

  @override
  State<FolderSelectionScreen> createState() => _FolderSelectionScreenState();
}

class _FolderSelectionScreenState extends State<FolderSelectionScreen> {
  bool _isScanning = false;

  // 缓存每个文件夹的统计信息
  final Map<String, Map<String, int>> _folderStats = {};
  // 跟踪正在计数的文件夹
  final Set<String> _scanningFolders = {};

  Future<void> _addFolder() async {
    if (Platform.isAndroid) {
      // Android 端使用 MediaStore 读取相册列表
      final hasPermission = await MediaStoreService.requestStoragePermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('需要存储权限才能读取图片'),
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
            const SnackBar(
              content: Text('未找到包含图片的相册'),
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
            title: const Text(
              '选择相册',
              style: TextStyle(color: Colors.white, fontSize: 18),
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
                        '${album.imageCount} 张图片',
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
                child: const Text(
                  '取消',
                  style: TextStyle(color: Colors.white70),
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
                child: const Text(
                  '确定',
                  style: TextStyle(
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
      // 桌面端使用 FilePicker
      final result = await FilePicker.platform.getDirectoryPath();
      if (result != null) {
        if (!mounted) return;
        final slideProvider = Provider.of<SlideProvider>(
          context,
          listen: false,
        );
        final settingsProvider = Provider.of<SettingsProvider>(
          context,
          listen: false,
        );
        slideProvider.addFolderPath(result);
        settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

        // 计算新添加文件夹的统计信息
        _countFolderImages(result);
      }
    }
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
      const supportedExtensions = {
        'jpg',
        'jpeg',
        'png',
        'webp',
        'bmp',
        'gif',
        'tiff',
        'tif',
      };

      int imageCount = 0;
      int subfolderCount = 0;

      if (Platform.isAndroid) {
        // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
        final images = await MediaStoreService.getFolderImages(folderPath);
        for (final item in images) {
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

  /// 构建文件夹统计信息的 widget
  Widget _buildFolderStats(String folderPath) {
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (_scanningFolders.contains(folderPath)) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    final stats = _folderStats[folderPath];
    if (stats == null) {
      return const SizedBox.shrink();
    }

    final imageCount = stats['imageCount'] ?? 0;
    final subfolderCount = stats['subfolderCount'] ?? 0;

    String countText;
    if (settingsProvider.recursiveScan) {
      countText = '包含$subfolderCount个子文件夹，共$imageCount个文件';
    } else {
      countText = '包含$imageCount个文件';
    }

    return Text(
      countText,
      style: const TextStyle(fontSize: 12, color: Colors.grey),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  void _removeFolder(String path) {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    slideProvider.removeFolderPath(path);
    settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

    // 清除缓存的统计信息
    setState(() {
      _folderStats.remove(path);
      _scanningFolders.remove(path);
    });
  }

  void _clearAll() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    slideProvider.clearFolderPaths();
    settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

    // 清除所有缓存的统计信息
    setState(() {
      _folderStats.clear();
      _scanningFolders.clear();
    });
  }

  /// 构建"已排除的文件"虚拟文件夹条目
  Widget _buildExcludedFolderTile() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final excludedCount = settings.excludedPaths.length;
    final loc = AppLocalizations.of(context);
    // 找第一张仍然存在的已排除图片作为缩略图
    String? firstExcludedPath;
    for (final path in settings.excludedPaths) {
      if (File(path).existsSync()) {
        firstExcludedPath = path;
        break;
      }
    }
    return ListTile(
      // 右侧边距缩小，让 > 图标更靠右，与左侧缩略图边距更平衡
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 40,
          height: 40,
          child: firstExcludedPath != null
              ? _ThumbnailImage(
                  thumbnailPath: firstExcludedPath,
                  albumPath: firstExcludedPath,
                )
              : Container(
                  color: const Color(0xFF1a1a2e),
                  child: const Icon(
                    Icons.inbox,
                    color: Colors.orange,
                    size: 24,
                  ),
                ),
        ),
      ),
      title: Text(
        loc.excludeFolderVirtual,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        excludedCount > 0 ? '包含 $excludedCount 张图片' : '暂无已排除的图片',
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      // 用与 IconButton 相同尺寸的容器包裹，保证与下方删除按钮竖向对齐
      trailing: const SizedBox(
        width: 48,
        height: 48,
        child: Icon(Icons.chevron_right, color: Colors.grey),
      ),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const ExcludedImagesScreen()),
        );
      },
    );
  }

  Future<void> _scanImages() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (slideProvider.folderPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先添加文件夹'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() {
      _isScanning = true;
    });

    try {
      // 使用 Map 进行去重
      final uniqueImages = <String, ImageItem>{};
      bool hasStartedPlaying = false;
      int lastUpdateCount = 0;

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final images = await _scanFolder(folderPath, settingsProvider);
        for (final image in images) {
          if (!uniqueImages.containsKey(image.path)) {
            uniqueImages[image.path] = image;
          }

          // 每收集到10张新图片就更新一次列表（播放中）
          if (hasStartedPlaying &&
              uniqueImages.length - lastUpdateCount >= 10) {
            final newImages = uniqueImages.values.toList()
              ..sort((a, b) => a.name.compareTo(b.name));
            slideProvider.setImages(newImages);
            lastUpdateCount = uniqueImages.length;
          }
        }

        // 如果已经收集到足够的图片且还未开始播放，则立即开始
        if (!hasStartedPlaying && uniqueImages.length >= 10) {
          await _startPlaybackEarly(
            uniqueImages.values.toList(),
            slideProvider,
            settingsProvider,
          );
          hasStartedPlaying = true;
          lastUpdateCount = uniqueImages.length;
        }
      }

      // 按文件名排序
      final sortedImages = uniqueImages.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      if (sortedImages.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('选定的目录下没有图片'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
        setState(() {
          _isScanning = false;
        });
        return;
      }

      if (!hasStartedPlaying) {
        // 如果图片少于10张，直接设置并返回
        slideProvider.setImages(sortedImages);
        settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('扫描完成，共 ${sortedImages.length} 张图片'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );

        if (!mounted) return;
        Navigator.pop(context);
      } else {
        // 已经在播放中，更新完整列表
        if (sortedImages.length != lastUpdateCount) {
          slideProvider.setImages(sortedImages);
          settingsProvider.setLastFolderPaths(slideProvider.folderPaths);
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('扫描失败: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _startPlaybackEarly(
    List<ImageItem> images,
    SlideProvider slideProvider,
    SettingsProvider settingsProvider,
  ) async {
    // 对已收集的图片进行排序
    final sortedImages = images.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    slideProvider.setImages(sortedImages);
    settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

    // 开始播放
    slideProvider.goToImage(0);
    slideProvider.startPlay();

    if (mounted) {
      Navigator.pushNamed(context, '/player');
    }
  }

  Future<List<ImageItem>> _scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) async {
    const supportedExtensions = {
      'jpg',
      'jpeg',
      'png',
      'webp',
      'bmp',
      'gif',
      'tiff',
      'tif',
    };

    // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
    if (Platform.isAndroid) {
      final images = await MediaStoreService.getFolderImages(folderPath);
      return images
          .where((item) {
            final dotIndex = item.path.lastIndexOf('.');
            if (dotIndex == -1) return false;
            final ext = item.path.toLowerCase().substring(dotIndex + 1);
            return supportedExtensions.contains(ext);
          })
          .map((item) => ImageItem(name: item.name, path: item.path))
          .toList();
    }

    // 桌面端使用文件系统 API
    List<File> files = [];

    if (settings.recursiveScan) {
      final dir = Directory(folderPath);
      await for (var entity in dir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }
    } else {
      final dir = Directory(folderPath);
      final entities = await dir.list().toList();
      files = entities.whereType<File>().toList();
    }

    return files
        .where((file) {
          final dotIndex = file.path.lastIndexOf('.');
          if (dotIndex == -1) return false;
          final ext = file.path.toLowerCase().substring(dotIndex + 1);
          return supportedExtensions.contains(ext);
        })
        .map(
          (file) => ImageItem(
            name: file.path.split(Platform.pathSeparator).last,
            path: file.path,
          ),
        )
        .toList();
  }

  bool _previousRecursiveScan = false;

  @override
  void initState() {
    super.initState();
    // 页面初始化时，对已有的文件夹触发统计计算
    Future.microtask(() {
      if (!mounted) return;
      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
      final settingsProvider = Provider.of<SettingsProvider>(
        context,
        listen: false,
      );
      _previousRecursiveScan = settingsProvider.recursiveScan;
      for (final path in slideProvider.folderPaths) {
        _countFolderImages(path);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当递归扫描设置变化时，重新计算所有文件夹的统计信息
    final settingsProvider = Provider.of<SettingsProvider>(context);
    if (_previousRecursiveScan != settingsProvider.recursiveScan) {
      _previousRecursiveScan = settingsProvider.recursiveScan;
      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
      // 清除缓存并重新计算
      setState(() {
        _folderStats.clear();
      });
      for (final path in slideProvider.folderPaths) {
        _countFolderImages(path);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择文件夹'),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
      ),
      body: Consumer2<SlideProvider, SettingsProvider>(
        builder: (context, slideProvider, settingsProvider, child) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // 已选文件夹列表
              Expanded(
                child: ListView.builder(
                  itemCount:
                      slideProvider.folderPaths.length +
                      (settingsProvider.excludedPaths.isNotEmpty ? 1 : 0),
                  itemBuilder: (context, index) {
                    final hasExcluded =
                        settingsProvider.excludedPaths.isNotEmpty;
                    // 第一个条目（如果有排除文件）是虚拟的"已排除的文件"文件夹
                    if (hasExcluded && index == 0) {
                      return Column(
                        children: [
                          _buildExcludedFolderTile(),
                          const Divider(height: 1, color: Colors.grey),
                        ],
                      );
                    }
                    final folderIndex = hasExcluded ? index - 1 : index;
                    final path = slideProvider.folderPaths[folderIndex];
                    return ListTile(
                      // 右侧边距缩小，让删除按钮更靠右，与左侧缩略图边距更平衡
                      contentPadding: const EdgeInsets.only(left: 16, right: 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: _ThumbnailImage(
                            thumbnailPath: null,
                            albumPath: path,
                          ),
                        ),
                      ),
                      title: Text(
                        // 安卓端手机宽度有限，只显示最后一级文件夹名；
                        // Windows 端保留完整路径
                        Platform.isAndroid ? _getLastPathSegment(path) : path,
                        style: const TextStyle(fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _buildFolderStats(path),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _removeFolder(path),
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                FolderImagesScreen(folderPath: path),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              // 操作按钮
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _addFolder,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0984e3),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 3,
                        shadowColor: const Color(
                          0xFF0984e3,
                        ).withValues(alpha: 0.3),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.add, size: 24),
                          const SizedBox(width: 12),
                          Text(
                            AppLocalizations.of(context).addFolder,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: slideProvider.folderPaths.isEmpty
                          ? null
                          : _clearAll,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFd63031),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 3,
                        shadowColor: const Color(
                          0xFFd63031,
                        ).withValues(alpha: 0.3),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.clear, size: 24),
                          const SizedBox(width: 12),
                          Text(
                            AppLocalizations.of(context).clearAll,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                    shadowColor: const Color(0xFF00b894).withValues(alpha: 0.4),
                  ),
                  child: _isScanning
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.play_circle, size: 24),
                            const SizedBox(width: 12),
                            Text(
                              AppLocalizations.of(context).startPlay,
                              style: const TextStyle(fontSize: 18),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
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

  const _ThumbnailImage({required this.thumbnailPath, required this.albumPath});

  @override
  State<_ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<_ThumbnailImage> {
  Uint8List? _imageBytes;
  bool _loading = true;

  static const _supportedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
    'tiff',
    'tif',
  };

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _ThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.thumbnailPath != widget.thumbnailPath) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    setState(() {
      _loading = true;
    });

    try {
      // 优先使用原生端返回的 content:// URI 或文件路径
      if (widget.thumbnailPath != null && widget.thumbnailPath!.isNotEmpty) {
        if (widget.thumbnailPath!.startsWith('content://')) {
          // 通过 MethodChannel 读取 content:// URI
          _imageBytes = await MediaStoreService.readImageBytes(
            widget.thumbnailPath!,
          );
        } else {
          // 直接读取文件路径
          final file = File(widget.thumbnailPath!);
          if (await file.exists()) {
            _imageBytes = await file.readAsBytes();
          }
        }
      }

      // 如果缩略图加载失败，尝试从相册文件夹中找第一张图片
      if (_imageBytes == null) {
        final dir = Directory(widget.albumPath);
        if (await dir.exists()) {
          await for (final entity in dir.list(recursive: false)) {
            if (entity is File) {
              final ext = entity.path.split('.').last.toLowerCase();
              if (_supportedExtensions.contains(ext)) {
                try {
                  _imageBytes = await entity.readAsBytes();
                  break;
                } catch (_) {}
              }
            }
          }
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
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
      return Image.memory(
        _imageBytes!,
        width: double.infinity,
        height: double.infinity,
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
