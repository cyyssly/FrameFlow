import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/providers/slide_provider.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/screens/folder_selection_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isAutoScanning = false;

  @override
  void initState() {
    super.initState();
    _autoPlayOnStartup();
  }

  Future<void> _autoPlayOnStartup() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    // 如果没有文件夹路径，直接返回
    if (slideProvider.folderPaths.isEmpty) {
      return;
    }

    setState(() {
      _isAutoScanning = true;
    });

    try {
      // 使用 Map 进行去重
      final uniqueImages = <String, ImageItem>{};
      bool hasStartedPlaying = false;
      DateTime lastUpdateTime = DateTime.now();
      const updateInterval = Duration(milliseconds: 300);

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final images = await _scanFolder(folderPath, settingsProvider);
        for (final image in images) {
          if (!uniqueImages.containsKey(image.path)) {
            uniqueImages[image.path] = image;
          }

          // 时间节流：每隔300ms更新一次列表，避免频繁UI更新
          final now = DateTime.now();
          if (now.difference(lastUpdateTime) >= updateInterval) {
            final newImages = uniqueImages.values.toList()
              ..sort((a, b) => a.name.compareTo(b.name));
            slideProvider.setImages(newImages);
            lastUpdateTime = now;
          }
        }

        // 如果开启了自动播放，且已经收集到足够的图片且还未开始播放，则立即开始
        if (settingsProvider.autoPlay &&
            !hasStartedPlaying &&
            uniqueImages.length >= 10) {
          await _startPlaybackEarly(
            uniqueImages.values.toList(),
            slideProvider,
          );
          hasStartedPlaying = true;
        }
      }

      // 按文件名排序
      final sortedImages = uniqueImages.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      if (sortedImages.isEmpty) {
        setState(() {
          _isAutoScanning = false;
        });
        return;
      }

      // 设置图片列表（无论是否自动播放都要设置）
      slideProvider.setImages(sortedImages);

      if (!hasStartedPlaying && settingsProvider.autoPlay) {
        // 如果开启了自动播放且还未开始，启动播放
        await Future.delayed(const Duration(milliseconds: 500));

        slideProvider.goToImage(0);
        slideProvider.togglePlay();
        if (mounted) {
          Navigator.pushNamed(context, '/player');
        }
      }
    } catch (e) {
      debugPrint('自动扫描失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isAutoScanning = false;
        });
      }
    }
  }

  Future<void> _startPlaybackEarly(
    List<ImageItem> images,
    SlideProvider slideProvider,
  ) async {
    // 对已收集的图片进行排序
    final sortedImages = images.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    slideProvider.setImages(sortedImages);

    await Future.delayed(const Duration(milliseconds: 300));

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

  Future<void> _startPlayback(BuildContext context) async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (slideProvider.folderPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先设置要播放幻灯的图片目录'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    // 总是重新扫描所有文件夹，确保获取完整的图片列表
    setState(() {
      _isAutoScanning = true;
    });

    try {
      // 使用 Map 进行去重
      final uniqueImages = <String, ImageItem>{};

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final images = await _scanFolder(folderPath, settingsProvider);
        for (final image in images) {
          if (!uniqueImages.containsKey(image.path)) {
            uniqueImages[image.path] = image;
          }
        }
      }

      // 按文件名排序
      final sortedImages = uniqueImages.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      if (sortedImages.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('选定的目录下没有图片，请重新选择'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

      slideProvider.setImages(sortedImages);

      slideProvider.goToImage(0);
      slideProvider.togglePlay();
      if (mounted) {
        Navigator.pushNamed(context, '/player');
      }
    } catch (e) {
      debugPrint('扫描图片失败: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('扫描图片失败，请重试'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAutoScanning = false;
        });
      }
    }
  }

  Future<void> _openDonatePage() async {
    final uri = Uri.parse('https://ifdian.net/a/sly345678/plan');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _selectFolder(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const FolderSelectionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('图片幻灯播放器'),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isAutoScanning) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text(
                '正在扫描图片...',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ] else ...[
              SizedBox(
                width: MediaQuery.of(context).size.width * 0.5,
                child: ElevatedButton(
                  onPressed: () => _startPlayback(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00b894),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 4,
                    shadowColor: const Color(0xFF00b894).withValues(alpha: 0.4),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.play_circle, size: 24),
                      SizedBox(width: 12),
                      Text('开始播放', style: TextStyle(fontSize: 18)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: MediaQuery.of(context).size.width * 0.5,
                child: ElevatedButton(
                  onPressed: () => _selectFolder(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0984e3),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 3,
                    shadowColor: const Color(0xFF0984e3).withValues(alpha: 0.3),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.folder_open, size: 24),
                      SizedBox(width: 12),
                      Text('选择图片', style: TextStyle(fontSize: 18)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: MediaQuery.of(context).size.width * 0.5,
                child: ElevatedButton(
                  onPressed: () => Navigator.pushNamed(context, '/settings'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6c5ce7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 3,
                    shadowColor: const Color(0xFF6c5ce7).withValues(alpha: 0.3),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.settings, size: 24),
                      SizedBox(width: 12),
                      Text('设置', style: TextStyle(fontSize: 18)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: MediaQuery.of(context).size.width * 0.5,
                child: ElevatedButton(
                  onPressed: _openDonatePage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFe17055),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 3,
                    shadowColor: const Color(0xFFe17055).withValues(alpha: 0.3),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.favorite, size: 24),
                      SizedBox(width: 12),
                      Text('赞助', style: TextStyle(fontSize: 18)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
