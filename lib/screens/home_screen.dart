import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/lan_provider.dart';
import 'package:frame_flow/screens/folder_selection_screen.dart';
import 'package:frame_flow/screens/help_screen.dart';
import 'package:frame_flow/screens/lan_devices_screen.dart';
import 'package:frame_flow/screens/player_screen.dart';
import 'package:frame_flow/services/image_scan_service.dart';
import 'package:frame_flow/utils/filename_compare.dart';
import 'package:frame_flow/l10n/app_localizations.dart';

class HomeScreen extends StatefulWidget {
  /// 由右键菜单/命令行传入、启动后直接播放的图片路径
  final String? initialImagePath;

  const HomeScreen({super.key, this.initialImagePath});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isAutoScanning = false;

  /// 扫描进度提示（如“正在读取某某共享文件夹……”）
  String _scanStatusText = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialImagePath != null) {
      // 从右键菜单打开：跳过自动扫描，直接播放该图片
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialImage());
    } else {
      _autoPlayOnStartup();
    }
  }

  /// 直接播放命令行传入的图片（只播放该文件，不扫描其所在目录）。
  void _openInitialImage() {
    final path = widget.initialImagePath;
    if (!mounted || path == null) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    slideProvider.setImages([
      ImageItem(name: path.split(Platform.pathSeparator).last, path: path),
    ]);
    slideProvider.startPlay();
    Navigator.pushNamed(context, '/player');
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
      final bool isRandomMode = settingsProvider.playOrder == PlayOrder.random;

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final images = await _scanFolder(folderPath, settingsProvider);
        for (final image in images) {
          uniqueImages[image.key] = image;

          // 随机模式：边扫描边播放，每隔300ms增量更新列表
          if (isRandomMode) {
            final now = DateTime.now();
            if (now.difference(lastUpdateTime) >= updateInterval) {
              final newImages = uniqueImages.values.toList()
                ..sort((a, b) => compareFileNames(a.name, b.name));
              if (hasStartedPlaying) {
                slideProvider.addNewImages(
                  newImages,
                  settingsProvider.playOrder,
                );
              } else {
                slideProvider.setImages(
                  newImages,
                  playOrder: settingsProvider.playOrder,
                );
                slideProvider.sortByPlayOrder(settingsProvider.playOrder);
              }
              lastUpdateTime = now;
            }
          }
        }

        // 随机模式：收集到>=10张且未开始播放 → 提前开始（仅随机模式）
        if (isRandomMode &&
            settingsProvider.autoPlay &&
            !hasStartedPlaying &&
            uniqueImages.length >= 10) {
          await _startPlaybackEarly(
            uniqueImages.values.toList(),
            slideProvider,
            settingsProvider,
          );
          hasStartedPlaying = true;
        }
      }

      // 所有文件夹扫描完毕
      final allImages = uniqueImages.values.toList()
        ..sort((a, b) => compareFileNames(a.name, b.name));

      if (allImages.isEmpty) {
        setState(() {
          _isAutoScanning = false;
        });
        return;
      }

      if (hasStartedPlaying) {
        // 随机模式已提前播放：增量添加剩余新图片
        slideProvider.addNewImages(allImages, settingsProvider.playOrder);
      } else {
        // 非随机模式（或图片不足10张）：全量设置并排序后开始播放
        slideProvider.setImages(
          allImages,
          playOrder: settingsProvider.playOrder,
        );
        slideProvider.sortByPlayOrder(settingsProvider.playOrder);

        if (settingsProvider.autoPlay) {
          await Future.delayed(const Duration(milliseconds: 500));

          if (!mounted) return;
          slideProvider.goToStartPosition(settingsProvider.playOrder);
          slideProvider.startPlay();
          if (mounted) {
            openPlayerScreen(context);
          }
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
    SettingsProvider settingsProvider,
  ) async {
    // 对已收集的图片进行排序
    final sortedImages = images.toList()
      ..sort((a, b) => compareFileNames(a.name, b.name));

    slideProvider.setImages(
      sortedImages,
      playOrder: settingsProvider.playOrder,
    );
    slideProvider.sortByPlayOrder(settingsProvider.playOrder);

    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;
    slideProvider.goToStartPosition(settingsProvider.playOrder);
    slideProvider.startPlay();
    if (mounted) {
      openPlayerScreen(context);
    }
  }

  Future<List<ImageItem>> _scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) => ImageScanService.scanFolder(folderPath, settings);

  Future<void> _startPlayback() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    final lanProvider = Provider.of<LanProvider>(context, listen: false);
    final sharedRefs = settingsProvider.sharedFolders;

    if (slideProvider.folderPaths.isEmpty && sharedRefs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).msgSelectFolderFirst),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // 总是重新扫描所有文件夹，确保获取完整的图片列表
    setState(() {
      _isAutoScanning = true;
      _scanStatusText = AppLocalizations.of(context).scanning;
    });

    try {
      // 使用 Map 进行去重
      final uniqueImages = <String, ImageItem>{};
      final loc = AppLocalizations.of(context);

      // 逐个扫描本地文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final images = await _scanFolder(folderPath, settingsProvider);
        for (final image in images) {
          uniqueImages[image.key] = image;
        }
      }

      // 继续读取共享文件夹（离线设备自动跳过），并提示当前读取进度
      if (sharedRefs.isNotEmpty) {
        await lanProvider.probeSharedDevices(sharedRefs);
        for (final ref in sharedRefs) {
          if (!mounted) return;
          if (!lanProvider.isDeviceReachable(ref.deviceId)) continue;
          setState(() {
            _scanStatusText = loc.readingSharedFolder(ref.folderName);
          });
          final images = await lanProvider.loadSharedFolderImages(ref);
          if (images == null) continue;
          for (final image in images) {
            uniqueImages[image.key] = image;
          }
        }
        if (!mounted) return;
        setState(() => _scanStatusText = loc.scanning);
      }

      // 按文件名排序
      final sortedImages = uniqueImages.values.toList()
        ..sort((a, b) => compareFileNames(a.name, b.name));

      if (sortedImages.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).msgReselectFolder),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }

      if (!mounted) return;
      slideProvider.setImages(
        sortedImages,
        playOrder: settingsProvider.playOrder,
      );
      slideProvider.sortByPlayOrder(settingsProvider.playOrder);

      slideProvider.goToStartPosition(settingsProvider.playOrder);
      slideProvider.startPlay();
      if (mounted) {
        openPlayerScreen(context);
      }
    } catch (e) {
      debugPrint('扫描图片失败: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).msgScanError),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAutoScanning = false;
          _scanStatusText = '';
        });
      }
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
    final isAndroid = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).homeTitle),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isAutoScanning) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  _scanStatusText.isEmpty
                      ? AppLocalizations.of(context).scanning
                      : _scanStatusText,
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.5,
                  child: ElevatedButton(
                    onPressed: () => _startPlayback(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00b894),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 4,
                      shadowColor: const Color(
                        0xFF00b894,
                      ).withValues(alpha: 0.4),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.play_circle, size: 24),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            AppLocalizations.of(context).startPlay,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.5,
                  child: isAndroid
                      ? ElevatedButton(
                          onPressed: () => _selectFolder(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0984e3),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            ),
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
                              const Icon(Icons.photo_library, size: 24),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  AppLocalizations.of(context).selectAlbum,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 18),
                                ),
                              ),
                            ],
                          ),
                        )
                      : ElevatedButton(
                          onPressed: () => _selectFolder(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0984e3),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            ),
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
                              const Icon(Icons.folder_open, size: 24),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  AppLocalizations.of(context).selectFolder,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 18),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.5,
                  child: ElevatedButton(
                    onPressed: () {
                      final slide = Provider.of<SlideProvider>(
                        context,
                        listen: false,
                      );
                      if (slide.folderPaths.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              AppLocalizations.of(context).lanShareNeedsFolders,
                            ),
                            backgroundColor: Colors.orange,
                          ),
                        );
                        return;
                      }
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LanDevicesScreen(),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00cec9),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 3,
                      shadowColor: const Color(
                        0xFF00cec9,
                      ).withValues(alpha: 0.3),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.devices, size: 24),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            AppLocalizations.of(context).lanSharePageTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
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
                        horizontal: 20,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 3,
                      shadowColor: const Color(
                        0xFF6c5ce7,
                      ).withValues(alpha: 0.3),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.settings, size: 24),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            AppLocalizations.of(context).settings,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.5,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pushNamed(context, '/help'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFe17055),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 3,
                      shadowColor: const Color(
                        0xFFe17055,
                      ).withValues(alpha: 0.3),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.help_outline, size: 24),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            AppLocalizations.of(context).help,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  appVersionLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
