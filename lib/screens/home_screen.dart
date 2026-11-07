import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:frame_flow/services/open_image_from_path.dart';
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
  /// 扫描是否进行中（用于忽略重复触发，提示显示在播放页）。
  bool _isAutoScanning = false;

  /// 正在进行的本地文件夹扫描。
  ///
  /// 启动自动播放的扫描与用户点击「开始播放」共用同一次扫描，
  /// 避免重复扫描同一批（可能上万张）图片。扫描结果不做缓存，
  /// 下次点击「开始播放」会重新扫描，以便感知磁盘上的新增/删除。
  Future<List<ImageItem>?>? _localScanInFlight;

  /// 当前扫描的中止标记。
  ///
  /// 每次扫描都新建一个标记，中止只会作用于对应的那一次扫描；
  /// 中止后立刻发起的重新扫描使用新标记，不会被旧标记影响。
  _ScanToken? _scanToken;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    if (widget.initialImagePath != null) {
      // 从右键菜单打开：跳过自动扫描，直接播放该图片
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialImage());
    } else {
      _autoPlayOnStartup();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    super.dispose();
  }

  /// 键盘快捷键：Enter 开始播放全部图片。
  ///
  /// [HardwareKeyboard] 会无条件调用所有已注册的 handler，因此这里必须确认
  /// 本页位于最上层，避免在设置页 / 浏览页 / 播放页中误触发。
  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // 扫描进行中（含启动自动播放的扫描）时重复按 Enter 直接忽略
      if (_isAutoScanning) return true;
      unawaited(_startPlayback());
      return true;
    }
    return false;
  }

  /// 直接打开命令行传入的图片：播放列表为图片所在文件夹（不递归子文件夹），
  /// 排序跟随该文件夹记录，否则用设置页默认顺序；打开后不自动播放。
  void _openInitialImage() {
    final path = widget.initialImagePath;
    if (!mounted || path == null) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    OpenImageFromPath.openImage(
      navigator: Navigator.of(context),
      slideProvider: slideProvider,
      settings: settingsProvider,
      imagePath: path,
    );
  }

  Future<void> _autoPlayOnStartup() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    // 没有文件夹路径，或关闭了「自动播放」时无需扫描：
    // 扫描只是为了自动开播，此时直接显示主界面，等用户点击「开始播放」再扫描。
    if (slideProvider.folderPaths.isEmpty || !settingsProvider.autoPlay) {
      return;
    }

    setState(() {
      _isAutoScanning = true;
    });
    // 立即进入播放页：扫描期间在播放页中央显示进度提示，
    // 用户不会看到主界面，也就不存在「停留在其他页面」的情况。
    slideProvider.setScanning(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 等待播放页关闭：若扫描尚未结束用户就退出了播放页，
      // 说明这次启动扫描已无意义，立即中止；下次点击「开始播放」重新扫描。
      unawaited(
        openPlayerScreen(context).then((_) {
          _abortScanIfPlayerClosed(slideProvider);
        }),
      );
    });

    _ScanToken? scanToken;
    try {
      bool hasStartedPlaying = false;
      DateTime lastUpdateTime = DateTime.now();
      const updateInterval = Duration(milliseconds: 300);
      final bool isRandomMode = settingsProvider.playOrder == PlayOrder.random;

      // 逐个文件夹扫描（与其他入口共用，可被「开始播放」复用）
      final scanFuture = _scanLocalFolders(
        slideProvider.folderPaths,
        settingsProvider,
        onFolderScanned: (collected, token) async {
          if (token.aborted) return;
          if (!isRandomMode || collected.isEmpty) return;

          // 随机模式：边扫描边播放，每隔300ms增量更新列表
          final now = DateTime.now();
          if (now.difference(lastUpdateTime) >= updateInterval) {
            final newImages = collected.values.toList()
              ..sort((a, b) => compareFileNames(a.name, b.name));
            if (hasStartedPlaying) {
              slideProvider.addNewImages(newImages, settingsProvider.playOrder);
            } else {
              slideProvider.setImages(
                newImages,
                playOrder: settingsProvider.playOrder,
              );
              slideProvider.sortByPlayOrder(settingsProvider.playOrder);
            }
            lastUpdateTime = now;
          }

          // 随机模式：收集到>=10张且未开始播放 → 提前开始（仅随机模式）
          if (!hasStartedPlaying && collected.length >= 10) {
            await _startPlaybackEarly(
              collected.values.toList(),
              slideProvider,
              settingsProvider,
              token,
            );
            hasStartedPlaying = true;
          }
        },
      );
      // _scanLocalFolders 同步创建并登记了本次扫描的中止标记
      scanToken = _scanToken;
      final allImages = await scanFuture;

      // 用户扫描期间退出播放页时扫描被中止，本次结果作废。
      if (allImages == null || allImages.isEmpty) {
        return;
      }

      if (hasStartedPlaying) {
        // 随机模式已提前播放：增量添加剩余新图片
        slideProvider.addNewImages(allImages, settingsProvider.playOrder);
      } else {
        // 非随机模式（或图片不足10张）：全量设置并排序后开始播放。
        // 播放页已在扫描开始前打开，这里只需启动播放。
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
        }
      }
    } catch (e) {
      debugPrint('自动扫描失败: $e');
    } finally {
      // 扫描被中止时状态已由 _abortScanIfPlayerClosed 重置；
      // 这里跳过，避免把中止后新发起的扫描状态一并清掉。
      if (!(scanToken?.aborted ?? false)) {
        slideProvider.setScanning(false);
        if (mounted) {
          setState(() {
            _isAutoScanning = false;
          });
        }
      }
    }
  }

  Future<void> _startPlaybackEarly(
    List<ImageItem> images,
    SlideProvider slideProvider,
    SettingsProvider settingsProvider,
    _ScanToken token,
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

    // 扫描已被中止（用户退出了播放页）时不再开始播放
    if (!mounted || token.aborted) return;
    slideProvider.goToStartPosition(settingsProvider.playOrder);
    slideProvider.startPlay();
  }

  Future<List<ImageItem>> _scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) => ImageScanService.scanFolder(folderPath, settings);

  /// 扫描全部本地文件夹（去重后按文件名排序）。
  ///
  /// 同一时刻只会有一次扫描在跑：若已有扫描进行中，直接返回该次扫描的
  /// 结果（启动自动播放与用户点击「开始播放」共享）；扫描结果不缓存，
  /// 每次点击「开始播放」都会重新扫描，以感知磁盘上的新增/删除。
  ///
  /// 返回 null 表示扫描被中止（用户扫描期间退出了播放页）。
  ///
  /// [onFolderScanned] 会在每扫完一个文件夹后回调，供启动流程做随机模式
  /// 的增量播放。
  Future<List<ImageItem>?> _scanLocalFolders(
    List<String> folders,
    SettingsProvider settings, {
    Future<void> Function(Map<String, ImageItem> collected, _ScanToken token)?
    onFolderScanned,
  }) {
    final inFlight = _localScanInFlight;
    if (inFlight != null) return inFlight;

    final token = _ScanToken();
    _scanToken = token;
    final unique = <String, ImageItem>{};
    late final Future<List<ImageItem>?> future;
    future = () async {
      for (final folderPath in folders) {
        final images = await _scanFolder(folderPath, settings);
        // 单个文件夹扫描（isolate）无法中途取消，只能在其返回后检查是否已中止
        if (token.aborted) return null;
        for (final image in images) {
          unique[image.key] = image;
        }
        if (onFolderScanned != null) {
          await onFolderScanned(Map.unmodifiable(unique), token);
          if (token.aborted) return null;
        }
      }
      return unique.values.toList()
        ..sort((a, b) => compareFileNames(a.name, b.name));
    }();

    _localScanInFlight = future;
    // 扫描结束（无论成功失败）后清空进行中标记；用 then 的 onError 承担
    // 错误，避免这个「收尾」future 因无人监听而产生未处理异常。
    future.then<void>(
      (_) => _clearScanInFlight(future),
      onError: (Object _) => _clearScanInFlight(future),
    );
    return future;
  }

  void _clearScanInFlight(Future<List<ImageItem>?> future) {
    if (identical(_localScanInFlight, future)) {
      _localScanInFlight = null;
    }
  }

  /// 播放页在扫描结束前被关闭时中止本次扫描。
  ///
  /// 扫描只为启动自动播放服务，用户已退出播放页时结果没有用处；
  /// 中止后下次点击「开始播放」会重新扫描，也能看到磁盘上的变化。
  void _abortScanIfPlayerClosed(SlideProvider slideProvider) {
    if (!_isAutoScanning) return;
    _scanToken?.aborted = true;
    // 立即清空进行中标记，让下次点击「开始播放」直接发起新扫描
    _localScanInFlight = null;
    _isAutoScanning = false;
    slideProvider.setScanning(false);
  }

  Future<void> _startPlayback() async {
    // 扫描进行中（含启动自动播放的扫描）忽略重复触发：
    // 否则连点会重复打开播放页、重复读取共享源
    if (_isAutoScanning) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    final lanProvider = Provider.of<LanProvider>(context, listen: false);
    final sharedRefs = settingsProvider.activeLibrarySharedFolders;

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

    final loc = AppLocalizations.of(context);
    _isAutoScanning = true;
    // 点击播放立即进入播放页：扫描在后台进行，播放页中央显示扫描提示。
    // 清空上一次的播放列表，避免播放页先用旧图片显示/播放。
    slideProvider.stopPlay();
    slideProvider.setImages(const []);
    slideProvider.setScanning(true, statusText: loc.scanning);
    unawaited(
      openPlayerScreen(context).then((_) {
        // 扫描途中用户按 ESC 退出播放页：中止扫描
        _abortScanIfPlayerClosed(slideProvider);
      }),
    );

    _ScanToken? scanToken;
    try {
      // 使用 Map 进行去重
      final uniqueImages = <String, ImageItem>{};

      // 扫描本地文件夹：若启动扫描仍在进行则复用同一次扫描（兜底/防抖），
      // 否则重新扫描；扫描结果不缓存，以便感知磁盘上的新增/删除。
      final scanFuture = _scanLocalFolders(
        slideProvider.folderPaths,
        settingsProvider,
      );
      // _scanLocalFolders 同步创建并登记了本次扫描的中止标记
      scanToken = _scanToken;
      final localImages = await scanFuture;
      // 扫描被中止（用户在扫描期间退出播放页），静默结束
      if (localImages == null) return;
      for (final image in localImages) {
        uniqueImages[image.key] = image;
      }

      // 继续读取共享文件夹（离线设备自动跳过），并提示当前读取进度
      if (sharedRefs.isNotEmpty) {
        await lanProvider.probeSharedDevices(sharedRefs);
        if (!_isAutoScanning) return;
        for (final ref in sharedRefs) {
          if (!_isAutoScanning || !mounted) return;
          if (!lanProvider.isSharedFolderReachable(ref)) continue;
          slideProvider.setScanning(
            true,
            statusText: loc.readingSharedFolder(ref.folderName),
          );
          final images = await lanProvider.loadSharedFolderImages(ref);
          if (!_isAutoScanning) return;
          if (images == null) continue;
          for (final image in images) {
            uniqueImages[image.key] = image;
          }
        }
        if (!_isAutoScanning) return;
        slideProvider.setScanning(true, statusText: loc.scanning);
      }

      final allImages = uniqueImages.values.toList();

      // 扫描途中已退出播放页：不再写入结果
      if (!_isAutoScanning) return;

      if (allImages.isEmpty) {
        if (!mounted) return;
        // 没有图片：先退回主界面，再提示
        Navigator.of(context).pop();
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
      slideProvider.setImages(allImages, playOrder: settingsProvider.playOrder);
      slideProvider.sortByPlayOrder(settingsProvider.playOrder);

      slideProvider.goToStartPosition(settingsProvider.playOrder);
      slideProvider.startPlay();
    } catch (e) {
      debugPrint('扫描图片失败: $e');
      if (!mounted) return;
      // 播放页仍在时先退回主界面，错误提示才能被看到
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).msgScanError),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      // 扫描被中止时状态已由 _abortScanIfPlayerClosed 重置；
      // 这里跳过，避免把中止后新发起的扫描状态一并清掉。
      if (!(scanToken?.aborted ?? false)) {
        _isAutoScanning = false;
        slideProvider.setScanning(false);
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
              ...[
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.5,
                  child: ElevatedButton(
                    // 点击后立即进入播放页，扫描在播放页中提示
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

/// 一次本地文件夹扫描的中止标记。
///
/// 扫描过程中用户退出播放页时把它置为 [aborted]，
/// 扫描循环在下一个检查点返回 null（结果作废）。
class _ScanToken {
  bool aborted = false;
}
