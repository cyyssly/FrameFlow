import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/providers/slide_provider.dart';
import 'package:slide_show/providers/settings_provider.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Timer? _autoPlayTimer;
  bool _showControls = true;
  Timer? _hideControlsTimer;
  bool _showInfo = true;
  Timer? _hideInfoTimer;
  double _scale = 1.0;
  double _rotation = 0.0;
  Offset _position = Offset.zero;
  Offset _startPosition = Offset.zero;
  double _startScale = 1.0;
  bool _wasPlayingBeforeDelete = false;
  bool _showDeleteMessage = false;
  String _deleteMessageText = '';
  double _autoRotation = 0.0;
  int _lastProcessedIndex = -1;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    // 初始化焦点
    _focusNode = FocusNode();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 请求焦点以接收键盘事件
      _focusNode.requestFocus();

      // 如果设置了自动全屏，先进入全屏再开始播放
      if (settings.startFullscreen) {
        // 延迟更长时间再进入全屏，确保窗口完全就绪
        Future.delayed(const Duration(milliseconds: 300), () {
          _enterFullscreen();

          // 全屏后再延迟一小段时间启动自动播放，确保窗口状态稳定
          Future.delayed(const Duration(milliseconds: 100), () {
            if ((settings.autoPlay || slideProvider.isPlaying) &&
                slideProvider.images.isNotEmpty) {
              if (!slideProvider.isPlaying) {
                slideProvider.togglePlay();
              }
              _startAutoPlay();
            }
          });
        });
      } else if (settings.autoPlay && slideProvider.images.isNotEmpty) {
        // 没有设置自动全屏时，直接启动自动播放
        if (!slideProvider.isPlaying) {
          slideProvider.togglePlay();
        }
        _startAutoPlay();
      } else if (slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
        // 如果已经处于播放状态（从外部设置的），确保定时器也启动
        _startAutoPlay();
      }

      // 应用屏幕方向设置
      _applyScreenOrientation(settings);

      // 在播放状态确定后再设置自动隐藏
      _hideControlsDelayed();
      _hideInfoDelayed();
    });
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 避免每次更新都重启定时器
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _hideControlsTimer?.cancel();
    _hideInfoTimer?.cancel();

    // 停止幻灯片播放
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (slideProvider.isPlaying) {
      slideProvider.togglePlay();
    }

    // 确保退出全屏状态，但不调用 setState
    if (_isFullscreen) {
      _restoreWindowState();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 恢复所有屏幕方向
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  /// 仅恢复窗口状态，不调用 setState，用于 dispose 时调用
  void _restoreWindowState() {
    if (Platform.isWindows && _originalStyle != null) {
      try {
        final user32 = DynamicLibrary.open('user32.dll');

        // 获取前台窗口句柄
        final getForegroundWindow = user32
            .lookupFunction<IntPtr Function(), int Function()>(
              'GetForegroundWindow',
            );
        var hwnd = getForegroundWindow();

        // 如果获取不到前台窗口，尝试通过窗口标题查找
        if (hwnd == 0) {
          final findWindowW = user32
              .lookupFunction<
                IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
                int Function(Pointer<Utf16>, Pointer<Utf16>)
              >('FindWindowW');
          hwnd = findWindowW(nullptr, 'FrameFlow'.toNativeUtf16());
        }

        if (hwnd != 0) {
          // 恢复原始窗口样式
          final setWindowLongPtr = user32
              .lookupFunction<
                IntPtr Function(IntPtr, Int32, IntPtr),
                int Function(int, int, int)
              >('SetWindowLongPtrW');
          setWindowLongPtr(hwnd, -16, _originalStyle!);

          // 恢复窗口到原始位置和大小
          final setWindowPos = user32
              .lookupFunction<
                Int32 Function(
                  IntPtr,
                  IntPtr,
                  Int32,
                  Int32,
                  Int32,
                  Int32,
                  Uint32,
                ),
                int Function(int, int, int, int, int, int, int)
              >('SetWindowPos');
          const hwndNotopmost = -2;

          if (_originalX != null &&
              _originalY != null &&
              _originalWidth != null &&
              _originalHeight != null) {
            setWindowPos(
              hwnd,
              hwndNotopmost,
              _originalX!,
              _originalY!,
              _originalWidth!,
              _originalHeight!,
              0,
            );
          } else {
            setWindowPos(hwnd, hwndNotopmost, 0, 0, 800, 600, 0);
          }
        }
      } catch (_) {
        // 忽略错误
      }
    }
  }

  /// 暂停播放
  void _pausePlayback() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    // 保存当前播放状态
    _wasPlayingBeforeDelete = slideProvider.isPlaying;
    if (slideProvider.isPlaying) {
      slideProvider.togglePlay();
    }
    _autoPlayTimer?.cancel();
  }

  /// 恢复播放
  void _resumePlayback() {
    // 只有在暂停前是播放状态时才恢复播放
    if (!_wasPlayingBeforeDelete) return;

    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (!slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
      slideProvider.togglePlay();
      _startAutoPlay();
    }
  }

  /// 显示播放完毕提示对话框
  void _showPlaybackCompleteDialog() {
    // 如果当前是全屏状态，先退出全屏再显示对话框
    if (_isFullscreen) {
      _exitFullscreen();
      // 延迟一小段时间让窗口状态稳定后再显示对话框
      Future.delayed(const Duration(milliseconds: 200), () {
        _showPlaybackCompleteAlert();
      });
    } else {
      _showPlaybackCompleteAlert();
    }
  }

  /// 实际显示播放完毕提示对话框
  void _showPlaybackCompleteAlert() {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false, // 必须点击确认才能关闭
      builder: (context) => AlertDialog(
        title: const Text('播放完毕'),
        content: const Text('所有图片已播放完毕'),
        actions: [
          TextButton(
            onPressed: () {
              // 返回主界面
              Navigator.pop(context); // 关闭对话框
              Navigator.pop(context); // 返回主界面
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 处理删除操作
  void _showDeleteConfirmation() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // 如果是排除播放，直接执行操作，不需要确认，也不需要退出全屏
    if (settings.deleteAction == DeleteAction.exclude) {
      _deleteCurrentImage();
      return;
    }

    // 如果是实际删除，暂停播放后显示确认对话框
    _pausePlayback();
    _showDeleteConfirmationDialog();
  }

  /// 实际显示删除确认对话框
  void _showDeleteConfirmationDialog() {
    if (!mounted) return;

    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final currentImage = slideProvider.images[slideProvider.currentIndex];
    final deleteActionText = settings.deleteAction == DeleteAction.exclude
        ? '排除播放'
        : '从磁盘删除';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          settings.deleteAction == DeleteAction.exclude ? '确认排除' : '确认删除',
        ),
        content: Text('确定要$deleteActionText这张图片吗？\n\n${currentImage.name}'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _resumePlayback();
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final imagesRemain = await _deleteCurrentImage();
              if (imagesRemain) {
                _resumePlayback();
              }
            },
            child: const Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// 显示删除通知（自定义覆盖层，在全屏模式下也能显示）
  void _showDeleteNotification(String message) {
    setState(() {
      _deleteMessageText = message;
      _showDeleteMessage = true;
    });

    // 2秒后自动隐藏
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _showDeleteMessage = false;
        });
      }
    });
  }

  /// 删除当前图片
  /// 返回 true 表示图片列表不为空，false 表示图片列表为空且已返回主界面
  Future<bool> _deleteCurrentImage() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final currentIndex = slideProvider.currentIndex;
    final currentImage = slideProvider.images[currentIndex];

    if (settings.deleteAction == DeleteAction.delete) {
      // 实际删除文件
      try {
        await File(currentImage.path).delete();
      } catch (e) {
        // 文件删除失败，可能是文件被占用（使用自定义覆盖层，在全屏模式下也能显示）
        if (mounted) {
          _showDeleteNotification('文件删除失败，可能被其他程序占用');
        }
        return true;
      }
    } else if (settings.deleteAction == DeleteAction.exclude) {
      // 排除播放：记录到已排除列表，供"选择文件夹"页面的"已排除的文件"使用
      settings.addExcludedPath(currentImage.path);
    }

    // 从播放列表中移除
    slideProvider.removeImage(currentIndex);

    // 如果图片列表为空，返回主界面
    if (slideProvider.images.isEmpty) {
      if (mounted) {
        Navigator.pop(context);
      }
      return false;
    } else {
      // 显示删除成功提示（使用自定义覆盖层，在全屏模式下也能显示）
      if (mounted) {
        _showDeleteNotification(
          settings.deleteAction == DeleteAction.exclude ? '图片已排除播放' : '图片已删除',
        );
      }
      return true;
    }
  }

  void _startAutoPlay() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    _autoPlayTimer?.cancel();

    // 根据当前播放状态启动或停止定时器
    if (slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
      _autoPlayTimer = Timer.periodic(
        Duration(milliseconds: settings.interval),
        (_) => _nextImage(),
      );
    }
  }

  void _nextImage() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (_scale != 1.0) {
      setState(() {
        _scale = 1.0;
        _rotation = 0.0;
        _position = Offset.zero;
      });
    }

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (!settings.loopPlay) {
      // 顺序/最新/最旧模式：检查是否到达最后一张图片
      final isSequentialOrder =
          settings.playOrder == PlayOrder.sequential ||
          settings.playOrder == PlayOrder.newestFirst ||
          settings.playOrder == PlayOrder.oldestFirst;
      if (isSequentialOrder &&
          slideProvider.currentIndex == slideProvider.images.length - 1) {
        slideProvider.togglePlay();
        _autoPlayTimer?.cancel();

        // 检查 widget 是否还挂载，避免在已销毁后调用 showDialog
        if (mounted) {
          // 显示播放完毕提示，用户确认后返回主界面
          _showPlaybackCompleteDialog();
        }
        return;
      }

      // 随机播放时，检查是否到达随机序列的最后一个位置
      if (settings.playOrder == PlayOrder.random &&
          slideProvider.isRandomPlaybackComplete()) {
        slideProvider.togglePlay();
        _autoPlayTimer?.cancel();

        // 检查 widget 是否还挂载，避免在已销毁后调用 showDialog
        if (mounted) {
          // 显示播放完毕提示，用户确认后返回主界面
          _showPlaybackCompleteDialog();
        }
        return;
      }
    }

    if (settings.playOrder == PlayOrder.random) {
      // 使用预打乱的随机序列进行播放
      slideProvider.nextRandomImage();
    } else {
      // 顺序/最新优先/最旧优先统一使用顺序索引播放
      slideProvider.nextImage();
    }
  }

  void _hideControlsDelayed() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    _hideControlsTimer?.cancel();

    // 如果关闭了隐藏工具栏选项，始终保持显示
    if (!settings.hideToolbar) {
      setState(() {
        _showControls = true;
      });
      return;
    }

    // 如果暂停时保持工具栏，则不自动隐藏
    if (settings.keepControlsOnPause && !slideProvider.isPlaying) {
      setState(() {
        _showControls = true;
      });
      return;
    }

    // 根据设置的延迟时间自动隐藏
    _hideControlsTimer = Timer(
      Duration(seconds: settings.controlsHideDelay),
      () {
        setState(() {
          _showControls = false;
        });
      },
    );
  }

  void _hideInfoDelayed() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _hideInfoTimer?.cancel();
    if (settings.infoAutoHide) {
      _hideInfoTimer = Timer(Duration(seconds: settings.infoHideDelay), () {
        setState(() {
          _showInfo = false;
        });
      });
    }
  }

  void _showControlsTemporarily() {
    setState(() {
      _showControls = true;
      _showInfo = true;
    });

    // 如果暂停时保持工具栏且当前处于暂停状态，不启动隐藏定时器
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    if (settings.keepControlsOnPause && !slideProvider.isPlaying) {
      // 暂停时保持工具栏，不启动隐藏定时器
      return;
    }

    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  void _togglePlay() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    slideProvider.togglePlay();

    // 如果现在是播放状态，启动定时器；否则停止
    if (slideProvider.isPlaying) {
      _startAutoPlay();
      _hideControlsDelayed();
    } else {
      _autoPlayTimer?.cancel();
      // 调用 _hideControlsDelayed() 来应用暂停时保持工具栏的逻辑
      _hideControlsDelayed();
    }
  }

  // 存储原始窗口样式和位置
  int? _originalStyle;
  int? _originalX, _originalY, _originalWidth, _originalHeight;
  // 键盘焦点
  late FocusNode _focusNode;
  // 全屏状态
  bool _isFullscreen = false;

  void _enterFullscreen() {
    // Windows 平台实现真正的独占全屏
    if (Platform.isWindows) {
      try {
        final user32 = DynamicLibrary.open('user32.dll');

        // 获取前台窗口句柄
        final getForegroundWindow = user32
            .lookupFunction<IntPtr Function(), int Function()>(
              'GetForegroundWindow',
            );
        var hwnd = getForegroundWindow();

        // 如果获取不到前台窗口，尝试通过窗口标题查找
        if (hwnd == 0) {
          final findWindowW = user32
              .lookupFunction<
                IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
                int Function(Pointer<Utf16>, Pointer<Utf16>)
              >('FindWindowW');
          hwnd = findWindowW(nullptr, 'FrameFlow'.toNativeUtf16());
        }

        // 如果仍然获取不到窗口句柄，直接返回
        if (hwnd == 0) {
          return;
        }

        // 先激活窗口，确保获取的是正确的窗口句柄
        final setForegroundWindow = user32
            .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'SetForegroundWindow',
            );
        setForegroundWindow(hwnd);

        // 获取屏幕分辨率
        final getSystemMetrics = user32
            .lookupFunction<Int32 Function(Int32), int Function(int)>(
              'GetSystemMetrics',
            );
        final screenWidth = getSystemMetrics(0); // SM_CXSCREEN
        final screenHeight = getSystemMetrics(1); // SM_CYSCREEN

        // 保存原始窗口样式
        final getWindowLongPtr = user32
            .lookupFunction<
              IntPtr Function(IntPtr, Int32),
              int Function(int, int)
            >('GetWindowLongPtrW');
        _originalStyle = getWindowLongPtr(hwnd, -16); // GWL_STYLE

        // 保存原始窗口位置和大小（使用 calloc 分配内存）
        final getWindowRect = user32
            .lookupFunction<
              Int32 Function(IntPtr, Pointer<Int32>),
              int Function(int, Pointer<Int32>)
            >('GetWindowRect');
        final rect = calloc<Int32>(4);
        getWindowRect(hwnd, rect);
        _originalX = rect[0];
        _originalY = rect[1];
        _originalWidth = rect[2] - rect[0];
        _originalHeight = rect[3] - rect[1];
        calloc.free(rect);

        // 移除窗口边框和标题栏
        final setWindowLongPtr = user32
            .lookupFunction<
              IntPtr Function(IntPtr, Int32, IntPtr),
              int Function(int, int, int)
            >('SetWindowLongPtrW');
        const wsOverlappedwindow = 0x00CF0000;
        const wsPopup = 0x80000000;
        setWindowLongPtr(
          hwnd,
          -16,
          _originalStyle! & ~wsOverlappedwindow | wsPopup,
        );

        // 设置窗口覆盖整个屏幕
        final setWindowPos = user32
            .lookupFunction<
              Int32 Function(
                IntPtr,
                IntPtr,
                Int32,
                Int32,
                Int32,
                Int32,
                Uint32,
              ),
              int Function(int, int, int, int, int, int, int)
            >('SetWindowPos');
        // 使用 HWND_TOPMOST 确保窗口在最顶层
        setWindowPos(
          hwnd,
          -1,
          0,
          0,
          screenWidth,
          screenHeight,
          0,
        ); // HWND_TOPMOST
      } catch (_) {
        // 忽略错误
      }
    }
    // 更新全屏状态
    setState(() {
      _isFullscreen = true;
    });
  }

  void _exitFullscreen() {
    // Windows 平台恢复窗口
    if (Platform.isWindows) {
      try {
        final user32 = DynamicLibrary.open('user32.dll');

        // 获取前台窗口句柄
        final getForegroundWindow = user32
            .lookupFunction<IntPtr Function(), int Function()>(
              'GetForegroundWindow',
            );
        var hwnd = getForegroundWindow();

        // 如果获取不到前台窗口，尝试通过窗口标题查找
        if (hwnd == 0) {
          final findWindowW = user32
              .lookupFunction<
                IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
                int Function(Pointer<Utf16>, Pointer<Utf16>)
              >('FindWindowW');
          hwnd = findWindowW(nullptr, 'FrameFlow'.toNativeUtf16());
        }

        // 如果仍然获取不到窗口句柄，直接返回
        if (hwnd == 0) {
          return;
        }

        // 恢复原始窗口样式
        if (_originalStyle != null) {
          final setWindowLongPtr = user32
              .lookupFunction<
                IntPtr Function(IntPtr, Int32, IntPtr),
                int Function(int, int, int)
              >('SetWindowLongPtrW');
          setWindowLongPtr(hwnd, -16, _originalStyle!);

          // 恢复窗口到原始位置和大小
          final setWindowPos = user32
              .lookupFunction<
                Int32 Function(
                  IntPtr,
                  IntPtr,
                  Int32,
                  Int32,
                  Int32,
                  Int32,
                  Uint32,
                ),
                int Function(int, int, int, int, int, int, int)
              >('SetWindowPos');
          const hwndNotopmost = -2; // 取消最顶层状态

          if (_originalX != null &&
              _originalY != null &&
              _originalWidth != null &&
              _originalHeight != null) {
            // 使用原始位置和大小恢复窗口，同时取消最顶层状态
            setWindowPos(
              hwnd,
              hwndNotopmost,
              _originalX!,
              _originalY!,
              _originalWidth!,
              _originalHeight!,
              0, // 移除 SWP_NOACTIVATE，允许窗口自动激活
            );
          } else {
            // 如果没有保存原始位置，使用默认恢复
            setWindowPos(hwnd, hwndNotopmost, 0, 0, 800, 600, 0);
          }

          // 在窗口样式和位置恢复后，再次显式激活窗口确保获取焦点
          final setForegroundWindow = user32
              .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
                'SetForegroundWindow',
              );
          setForegroundWindow(hwnd);

          // 额外调用 SetFocus 确保窗口获得输入焦点
          final setFocus = user32
              .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
                'SetFocus',
              );
          setFocus(hwnd);
        }
      } catch (_) {
        // 忽略错误
      }
    }
    // 更新全屏状态
    setState(() {
      _showControls = true;
      _isFullscreen = false;
    });
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startPosition = details.focalPoint - _position;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      _scale = math.min(math.max(_startScale * details.scale, 1.0), 5.0);
      _position = details.focalPoint - _startPosition;
    });
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    if (_scale <= 1.0) {
      setState(() {
        _scale = 1.0;
        _position = Offset.zero;
      });
    }
  }

  void _rotateImage() {
    setState(() {
      _rotation += math.pi / 2;
    });
  }

  /// 重新扫描图片文件夹
  Future<void> _rescanImages() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (slideProvider.folderPaths.isEmpty) {
      _showDeleteNotification('没有选择文件夹');
      return;
    }

    // 保存当前图片路径，以便扫描后恢复位置
    final currentPath = slideProvider.images.isNotEmpty
        ? slideProvider.images[slideProvider.currentIndex].path
        : null;

    _showDeleteNotification('正在重新扫描...');

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

      // 使用 Map 进行去重
      final uniqueImages = <String, ImageItem>{};

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        List<File> files = [];

        if (settingsProvider.recursiveScan) {
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

        for (final file in files) {
          final dotIndex = file.path.lastIndexOf('.');
          if (dotIndex == -1) continue;
          final ext = file.path.toLowerCase().substring(dotIndex + 1);
          if (supportedExtensions.contains(ext)) {
            final imageItem = ImageItem(
              name: file.path.split(Platform.pathSeparator).last,
              path: file.path,
            );
            if (!uniqueImages.containsKey(imageItem.path)) {
              uniqueImages[imageItem.path] = imageItem;
            }
          }
        }
      }

      // 按文件名排序
      final sortedImages = uniqueImages.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      // 更新图片列表
      slideProvider.setImages(sortedImages);

      // 尝试恢复到之前的图片位置
      if (currentPath != null && sortedImages.isNotEmpty) {
        final newIndex = sortedImages.indexWhere(
          (image) => image.path == currentPath,
        );
        if (newIndex != -1) {
          slideProvider.goToImage(newIndex);
        } else {
          // 如果之前的图片不在新列表中，从第一张开始
          slideProvider.goToImage(0);
        }
      }

      _showDeleteNotification('扫描完成，共 ${sortedImages.length} 张图片');
    } catch (e) {
      _showDeleteNotification('扫描失败: $e');
    }
  }

  /// 退出播放：停止自动播放、暂停播放并返回主界面
  void _exitPlayback() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    // 停止自动播放定时器
    _autoPlayTimer?.cancel();
    // 如果正在播放，暂停播放
    if (slideProvider.isPlaying) {
      slideProvider.togglePlay();
    }
    // 返回主界面
    Navigator.pop(context);
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.space:
          _togglePlay();
          break;
        case LogicalKeyboardKey.arrowLeft:
          Provider.of<SlideProvider>(context, listen: false).prevImage();
          break;
        case LogicalKeyboardKey.arrowRight:
          _nextImage();
          break;
        case LogicalKeyboardKey.escape:
          // 全屏时按 ESC 退出全屏；非全屏时按 ESC 退出播放
          if (_isFullscreen) {
            _exitFullscreen();
          } else {
            _exitPlayback();
          }
          break;
        case LogicalKeyboardKey.keyR:
          _rescanImages();
          break;
      }
    }
  }

  void _handleScroll(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      if (settings.wheelSwitchImage) {
        // 滚轮切换图片（不触发工具栏显示）
        if (event.scrollDelta.dy > 0) {
          _nextImage();
        } else if (event.scrollDelta.dy < 0) {
          Provider.of<SlideProvider>(context, listen: false).prevImage();
        }
      } else {
        // 滚轮缩放图片
        setState(() {
          if (event.scrollDelta.dy > 0) {
            _scale = math.max(_scale - 0.2, 1.0);
          } else {
            _scale = math.min(_scale + 0.2, 5.0);
          }
          if (_scale <= 1.0) {
            _position = Offset.zero;
          }
        });
      }
    }
  }

  String _getFileSize(String path) {
    try {
      final file = File(path);
      final size = file.lengthSync();
      if (size < 1024) return '$size B';
      if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '未知';
    }
  }

  String _getImageResolution(String path) {
    try {
      final image = img.decodeImage(File(path).readAsBytesSync());
      if (image != null) {
        return '${image.width} x ${image.height}';
      }
    } catch (_) {}
    return '未知';
  }

  /// 根据图片方向设置，更新自动旋转角度
  void _updateOrientationRotation(
    SlideProvider slideProvider,
    SettingsProvider settings,
  ) {
    if (slideProvider.images.isEmpty) return;

    final imagePath = slideProvider.images[slideProvider.currentIndex].path;

    switch (settings.imageOrientation) {
      case ImageOrientation.landscape:
        // 强制横屏：如果图片是竖屏的，旋转90°
        _autoRotation = _isPortraitImage(imagePath) ? math.pi / 2 : 0.0;
        break;
      case ImageOrientation.portrait:
        // 强制竖屏：如果图片是横屏的，旋转90°
        _autoRotation = _isLandscapeImage(imagePath) ? math.pi / 2 : 0.0;
        break;
      case ImageOrientation.followSystem:
        _autoRotation = 0.0;
        break;
      case ImageOrientation.followImage:
        // 跟随图片：让图片的长边对齐屏幕长边
        _autoRotation = _getRotationToMatchScreen(imagePath);
        break;
    }
  }

  /// 计算让图片长边对齐屏幕长边所需的旋转角度
  double _getRotationToMatchScreen(String path) {
    try {
      final image = img.decodeImage(File(path).readAsBytesSync());
      if (image == null) return 0.0;

      final size = MediaQuery.of(context).size;
      final isScreenLandscape = size.width >= size.height;
      final isImageLandscape = image.width >= image.height;

      // 如果图片方向和屏幕方向不一致，旋转90°使长边对齐
      if (isScreenLandscape != isImageLandscape) {
        return math.pi / 2;
      }
      return 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  bool _isPortraitImage(String path) {
    try {
      final image = img.decodeImage(File(path).readAsBytesSync());
      return image != null && image.height > image.width;
    } catch (_) {
      return false;
    }
  }

  bool _isLandscapeImage(String path) {
    try {
      final image = img.decodeImage(File(path).readAsBytesSync());
      return image != null && image.width > image.height;
    } catch (_) {
      return false;
    }
  }

  /// 根据设置锁定屏幕方向（移动端使用）
  void _applyScreenOrientation(SettingsProvider settings) {
    switch (settings.imageOrientation) {
      case ImageOrientation.landscape:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case ImageOrientation.portrait:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        break;
      case ImageOrientation.followSystem:
      case ImageOrientation.followImage:
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
    }
  }

  Widget _buildTransitionAnimation(Widget child, int index) {
    final settings = Provider.of<SettingsProvider>(context);

    switch (settings.transitionAnimation) {
      case TransitionAnimation.none:
        return child;
      case TransitionAnimation.fade:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: child,
        );
      case TransitionAnimation.slideLeft:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: child,
        );
      case TransitionAnimation.slideRight:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: child,
        );
      case TransitionAnimation.slideUp:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: child,
        );
      case TransitionAnimation.slideDown:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: child,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<SlideProvider, SettingsProvider>(
      builder: (context, slideProvider, settings, child) {
        if (slideProvider.images.isEmpty) {
          return Scaffold(
            backgroundColor: settings.background,
            body: const Center(child: Text('没有图片')),
          );
        }

        // 图片索引变化时更新方向旋转
        if (slideProvider.currentIndex != _lastProcessedIndex) {
          _lastProcessedIndex = slideProvider.currentIndex;
          _updateOrientationRotation(slideProvider, settings);
          _applyScreenOrientation(settings);
        }

        return Scaffold(
          backgroundColor: settings.background,
          body: KeyboardListener(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Listener(
              onPointerSignal: _handleScroll,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) {
                  // 立即显示控件，不等待 tap 事件完成
                  _showControlsTemporarily();
                },
                onTap: () {
                  _showControlsTemporarily();
                },
                onHorizontalDragEnd: (details) {
                  if (details.primaryVelocity! > 50) {
                    slideProvider.prevImage(playOrder: settings.playOrder);
                  } else if (details.primaryVelocity! < -50) {
                    _nextImage();
                  }
                },
                onScaleStart: _handleScaleStart,
                onScaleUpdate: _handleScaleUpdate,
                onScaleEnd: _handleScaleEnd,
                onSecondaryTap: () => _rotateImage(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildTransitionAnimation(
                      Transform(
                        key: ValueKey(slideProvider.currentIndex),
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..scale(_scale)
                          ..rotateZ(_rotation + _autoRotation)
                          ..translate(_position.dx, _position.dy),
                        child: Image.file(
                          File(
                            slideProvider
                                .images[slideProvider.currentIndex]
                                .path,
                          ),
                          fit: settings.boxFit,
                          errorBuilder: (context, error, stackTrace) =>
                              const Center(child: Text('图片加载失败')),
                        ),
                      ),
                      slideProvider.currentIndex,
                    ),
                    if (_showControls)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: AppBar(
                          backgroundColor: Colors.black.withValues(alpha: 0.5),
                          title: Text(
                            '${slideProvider.currentIndex + 1} / ${slideProvider.images.length}',
                            style: const TextStyle(fontSize: 16),
                          ),
                          leading: Tooltip(
                            message: '返回',
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () {
                                // 如果当前是全屏状态，先退出全屏再返回
                                if (_isFullscreen) {
                                  _exitFullscreen();
                                  // 延迟一小段时间让窗口状态稳定后再返回
                                  Future.delayed(
                                    const Duration(milliseconds: 200),
                                    () => Navigator.pop(context),
                                  );
                                } else {
                                  Navigator.pop(context);
                                }
                              },
                            ),
                          ),
                          actions: [
                            // 全屏/退出全屏按钮仅在 Windows 桌面端显示
                            // （手机端播放本身即全屏，无需切换）
                            if (Platform.isWindows)
                              Tooltip(
                                message: _isFullscreen ? '退出全屏' : '全屏',
                                child: IconButton(
                                  icon: Icon(
                                    _isFullscreen
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen,
                                  ),
                                  onPressed: _isFullscreen
                                      ? _exitFullscreen
                                      : _enterFullscreen,
                                ),
                              ),
                            Tooltip(
                              message:
                                  settings.deleteAction == DeleteAction.exclude
                                  ? '排除播放'
                                  : '删除文件',
                              child: IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                onPressed: _showDeleteConfirmation,
                              ),
                            ),
                            Tooltip(
                              message: '旋转',
                              child: IconButton(
                                icon: const Icon(Icons.rotate_right),
                                onPressed: _rotateImage,
                              ),
                            ),
                            Tooltip(
                              message: '设置',
                              child: IconButton(
                                icon: const Icon(Icons.settings),
                                onPressed: () =>
                                    Navigator.pushNamed(context, '/settings'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_showControls)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.5),
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              if (settings.showImageInfo && _showInfo)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        slideProvider
                                            .images[slideProvider.currentIndex]
                                            .name,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Text(
                                        _getFileSize(
                                          slideProvider
                                              .images[slideProvider
                                                  .currentIndex]
                                              .path,
                                        ),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Text(
                                        _getImageResolution(
                                          slideProvider
                                              .images[slideProvider
                                                  .currentIndex]
                                              .path,
                                        ),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.skip_previous,
                                      size: 36,
                                    ),
                                    color: Colors.white,
                                    onPressed: () {
                                      slideProvider.prevImage();
                                      _showControlsTemporarily();
                                    },
                                  ),
                                  const SizedBox(width: 32),
                                  IconButton(
                                    icon: Icon(
                                      slideProvider.isPlaying
                                          ? Icons.pause_circle
                                          : Icons.play_circle,
                                      size: 64,
                                    ),
                                    color: Colors.white,
                                    onPressed: _togglePlay,
                                  ),
                                  const SizedBox(width: 32),
                                  IconButton(
                                    icon: const Icon(Icons.skip_next, size: 36),
                                    color: Colors.white,
                                    onPressed: () {
                                      _nextImage();
                                      _showControlsTemporarily();
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    // 删除通知覆盖层
                    if (_showDeleteMessage)
                      Positioned(
                        top: 100,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _deleteMessageText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 60,
                      right: 16,
                      child: Column(
                        children: [
                          if (_scale > 1.0)
                            FloatingActionButton(
                              mini: true,
                              onPressed: () => setState(() {
                                _scale = 1.0;
                                _position = Offset.zero;
                              }),
                              child: const Icon(Icons.zoom_out),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
