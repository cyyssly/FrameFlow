import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/providers/slide_provider.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/screens/excluded_images_screen.dart';
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
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
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

  /// 计算文件夹中的图片数量和子文件夹数量
  Future<void> _countFolderImages(String folderPath) async {
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (_scanningFolders.contains(folderPath)) return;

    setState(() {
      _scanningFolders.add(folderPath);
    });

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

      if (settingsProvider.recursiveScan) {
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

      setState(() {
        _folderStats[folderPath] = {
          'imageCount': imageCount,
          'subfolderCount': subfolderCount,
        };
        _scanningFolders.remove(folderPath);
      });
    } catch (_) {
      setState(() {
        _folderStats[folderPath] = {'imageCount': 0, 'subfolderCount': 0};
        _scanningFolders.remove(folderPath);
      });
    }
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
    return ListTile(
      leading: const Icon(Icons.inbox, color: Colors.orange),
      title: Text(
        loc.excludeFolderVirtual,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        excludedCount > 0 ? '包含 $excludedCount 张图片' : '暂无已排除的图片',
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('扫描完成，共 ${sortedImages.length} 张图片'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );

        Navigator.pop(context);
      } else {
        // 已经在播放中，更新完整列表
        if (sortedImages.length != lastUpdateCount) {
          slideProvider.setImages(sortedImages);
          settingsProvider.setLastFolderPaths(slideProvider.folderPaths);
        }
      }
    } catch (e) {
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
    slideProvider.togglePlay();

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
                      leading: const Icon(Icons.folder, color: Colors.blue),
                      title: Text(
                        path,
                        style: const TextStyle(fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _buildFolderStats(path),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _removeFolder(path),
                      ),
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
}
