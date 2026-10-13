import 'dart:async';
// dart:ffi 也导出了 Size（原生 size_t 结构体），会与 dart:ui 的 Size 冲突，
// 本文件只用到 PowerSqlite/指针相关类型，故隐藏掉它的 Size。
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:slide_show/models/image_item.dart';
import 'package:slide_show/providers/slide_provider.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/services/media_store_service.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:wakelock_plus/wakelock_plus.dart';

/// 在后台 isolate 中解码图片并取回原始像素尺寸。
///
/// 顶层函数才能作为 [compute] 的入口；返回 null 表示解码失败。
Size? _decodeImageSize(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    return Size(image.width.toDouble(), image.height.toDouble());
  } catch (_) {
    return null;
  }
}

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

  /// 缩放/平移手势进行中。
  ///
  /// 手势期间不弹出工具栏（避免双指缩放时工具栏反复闪现干扰体验），
  /// 改为顺延隐藏计时器：手指一直按着就保持隐藏，松手后才重新计时。
  bool _isGestureActive = false;

  /// 当前按在屏幕上的手指数，用于判断“是否真的完全松手”。
  int _pointerCount = 0;

  /// 本轮交互中第一根手指按下的位置（全局逻辑坐标）。
  ///
  /// 用于在松手时判断这次“轻点”是否落在工具栏的按钮上。
  /// 工具栏内的按钮有自己的 onPressed，若把“点按钮”也当成“轻点画面”，
  /// 就会在按钮回调改完状态后立刻把工具栏隐藏掉（例如点播放/暂停后
  /// 工具栏一闪就消失、自动播放计时器被取消），表现为“按钮点了没反应”。
  Offset? _pointerDownPosition;

  /// 顶部工具栏（AppBar）、底部按钮行、右下角缩放按钮的位置引用，
  /// 用于判断按下的落点是否在工具栏内（见 [_isPointOnToolbar]）。
  final GlobalKey _topControlsKey = GlobalKey();
  final GlobalKey _bottomControlsKey = GlobalKey();
  final GlobalKey _zoomControlsKey = GlobalKey();

  /// 本轮交互中指尖漂移的最大距离（逻辑像素）。
  ///
  /// 用手势起点到当前焦点的总位移判定“是否发生了拖动”，
  /// 而不是单帧位移——缓慢拖动时每帧位移都小于阈值，
  /// 用单帧判定会被误认为“轻点”。
  double _gestureTravel = 0.0;

  /// 本轮交互是否曾同时出现两根及以上手指（双指捏合）。
  bool _multiPointerUsed = false;

  /// 本次手势是否发生了位移或缩放。
  /// 未发生则视为“轻点”，可在松手时切换工具栏显隐。
  bool _gestureMoved = false;

  /// 判定“轻点 vs 拖动”的位移阈值（逻辑像素）。
  /// 取 kTouchSlop 同量级，与框架对“拖动”的认定保持一致。
  static const double _tapMoveSlop = 18.0;

  // ---- 图片缩放/平移 ----
  /// 最小缩放倍数（1.0 即“适应屏幕”）
  static const double _minScale = 1.0;

  /// 最大缩放倍数
  static const double _maxScale = 5.0;

  /// 判定“已放大”的浮点容差
  static const double _zoomEpsilon = 0.01;

  /// 越过边界多少逻辑像素后才算“靠泊”/触发切换，避免手指抖动误触发
  static const double _dockPushThreshold = 24.0;

  /// 未放大时按滑动速度切换图片的阈值（逻辑像素/秒）
  static const double _swipeVelocityThreshold = 50.0;

  double _scale = 1.0;
  double _rotation = 0.0;
  Offset _position = Offset.zero;
  Offset _startPosition = Offset.zero;
  double _startScale = 1.0;

  /// 手势开始时焦点相对视口中心的位置
  Offset _startFocal = Offset.zero;

  /// 视口尺寸（由 [LayoutBuilder] 的布局结果缓存）。
  /// 在 build 期间只写入这个字段（而非 _viewportCenter），
  /// 视口中心由 [_viewportCenter] 计算得到。
  Size? _viewportSizeCache;

  /// 当前停靠的横向边缘：-1 靠泊在左边缘（继续右移→上一张）、
  /// 1 靠泊在右边缘（继续左移→下一张）、0 未靠泊。
  int _dockedEdge = 0;

  /// 靠泊判定锚点：记录“抵达/完成靠泊”时的横向位移。
  /// 之后必须再向外推 [_dockPushThreshold] 像素才触发切换，
  /// 保证“靠泊一次”与“再次移动切换”是两个独立动作。
  double _dockAnchorX = 0.0;

  /// 手势过程中触发切图后，忽略本次手势剩余的 update 事件。
  ///
  /// 否则 _startScale / _startPosition 仍是上一张图的手势初值，
  /// 这些旧值会被重新套用到新图上，导致刚切换又立即跳回放大状态。
  bool _suppressGestureUntilEnd = false;

  /// 本次手势中是否出现过捏合（双指缩放）。
  /// 用于在松手时区分“滑动切图”与“捏合缩放”，避免缩回原尺寸时误翻页。
  bool _gesturePinched = false;

  /// 当前图片的原始像素尺寸，用于计算平移边界
  Size? _intrinsicSize;
  int _intrinsicSizeForIndex = -1;
  ImageStream? _intrinsicStream;
  ImageStreamListener? _intrinsicListener;

  /// 包裹图片区域的 GestureDetector，用于取得真实视口尺寸
  final GlobalKey _gestureKey = GlobalKey();

  bool _wasPlayingBeforeDelete = false;
  bool _showDeleteMessage = false;
  String _deleteMessageText = '';
  double _autoRotation = 0.0;
  int _lastProcessedIndex = -1;

  /// 文件大小与分辨率缓存的加载中标记（防止重复请求）
  final Set<String> _metaLoading = {};

  // ---- 图片元信息缓存（避免在 build 中同步解码/读盘） ----
  /// 缓存的文件大小与分辨率文本，键为图片路径。
  /// 原先这两个信息在 build 里同步调用（含整张图片解码），
  /// 触摸显示工具栏时会导致每帧解码一次 → 手势严重掉帧。
  final Map<String, String> _fileSizeCache = {};
  final Map<String, String> _resolutionCache = {};

  // 记录最近一次已应用的运行时设置，用于检测设置变更并及时应用
  int _lastInterval = -1;
  ImageOrientation _lastOrientation = ImageOrientation.followSystem;
  int _lastControlsHideDelay = -1;
  bool _lastHideToolbar = true;
  int _lastInfoHideDelay = -1;
  bool _lastInfoAutoHide = true;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    // 播放时保持屏幕常亮，避免进入省电模式自动熄屏
    WakelockPlus.enable();

    // 初始化最近一次设置快照，避免首帧误判为设置变更
    _lastInterval = settings.interval;
    _lastOrientation = settings.imageOrientation;
    _lastControlsHideDelay = settings.controlsHideDelay;
    _lastHideToolbar = settings.hideToolbar;
    _lastInfoHideDelay = settings.infoHideDelay;
    _lastInfoAutoHide = settings.infoAutoHide;

    // 注册全局键盘监听器，不依赖 FocusNode
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 请求焦点以接收键盘事件

      // 如果设置了自动全屏，先进入全屏再开始播放
      if (settings.startFullscreen) {
        // 延迟更长时间再进入全屏，确保窗口完全就绪
        Future.delayed(const Duration(milliseconds: 300), () {
          _enterFullscreen();

          // 全屏后再延迟一小段时间启动自动播放，确保窗口状态稳定
          Future.delayed(const Duration(milliseconds: 100), () {
            if (slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
              _startAutoPlay();
            }
          });
        });
      } else if (slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
        // 如果正处于播放状态，启动自动播放定时器
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

  /// 检测设置变更并将运行时效果（轮播间隔、屏幕方向、自动隐藏等）即时应用。
  /// 由于 build 中不能调用 setState，将真正应用动作延迟到本次 build 完成后执行。
  void _applySettingsToPlayback(SettingsProvider settings) {
    final intervalChanged = settings.interval != _lastInterval;
    final orientationChanged = settings.imageOrientation != _lastOrientation;
    final controlsChanged =
        settings.controlsHideDelay != _lastControlsHideDelay ||
        settings.hideToolbar != _lastHideToolbar;
    final infoChanged =
        settings.infoHideDelay != _lastInfoHideDelay ||
        settings.infoAutoHide != _lastInfoAutoHide;

    _lastInterval = settings.interval;
    _lastOrientation = settings.imageOrientation;
    _lastControlsHideDelay = settings.controlsHideDelay;
    _lastHideToolbar = settings.hideToolbar;
    _lastInfoHideDelay = settings.infoHideDelay;
    _lastInfoAutoHide = settings.infoAutoHide;

    if (!intervalChanged &&
        !orientationChanged &&
        !controlsChanged &&
        !infoChanged) {
      return;
    }

    // 延迟到 build 完成后应用，避免 build 中调用 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (intervalChanged) {
        _startAutoPlay();
      }
      if (orientationChanged) {
        _applyScreenOrientation(settings);
      }
      if (controlsChanged) {
        _hideControlsDelayed();
      }
      if (infoChanged) {
        _hideInfoDelayed();
      }
    });
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _hideControlsTimer?.cancel();
    _hideInfoTimer?.cancel();
    // 释放用于读取图片尺寸的图片流监听
    _detachIntrinsicSizeListener();
    // 移除全局键盘监听器
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);

    // 释放屏幕常亮，恢复系统正常熄屏行为
    WakelockPlus.disable();

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
      slideProvider.stopPlay();
    }
    _autoPlayTimer?.cancel();
  }

  /// 恢复播放
  void _resumePlayback() {
    // 只有在暂停前是播放状态时才恢复播放
    if (!_wasPlayingBeforeDelete) return;

    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (!slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
      slideProvider.startPlay();
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

  /// 切换下一张图片。
  /// [manual] 为 true 表示由用户手动触发（键盘/滚轮/滑动/工具栏按钮），
  /// 切换后需要重置自动播放计时器。
  void _nextImage({bool manual = false}) {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    // 放大查看细节时不自动切图，避免用户正在看时被定时器切走
    if (!manual && _isZoomed) return;

    if (_scale != _minScale) {
      setState(() {
        _scale = _minScale;
        _rotation = 0.0;
        _position = Offset.zero;
        _dockedEdge = 0;
        _dockAnchorX = 0.0;
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
        slideProvider.stopPlay();
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
        slideProvider.stopPlay();
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

    // 手动切换后重置自动播放计时器，让下一张的等待时间从当前时刻重新计算
    if (manual) {
      _startAutoPlay();
    }
  }

  /// 手动切换到上一张图片（键盘/滚轮/滑动/工具栏按钮触发）。
  /// 切换后重置自动播放计时器，让等待时间从当前时刻重新计算。
  void _prevImage() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 切图后回到「适应屏幕」状态，避免新图带着上一张的缩放/位移
    if (_scale != _minScale) {
      setState(() {
        _scale = _minScale;
        _rotation = 0.0;
        _position = Offset.zero;
        _dockedEdge = 0;
        _dockAnchorX = 0.0;
      });
    }
    Provider.of<SlideProvider>(
      context,
      listen: false,
    ).prevImage(playOrder: settings.playOrder);
    _startAutoPlay();
  }

  void _hideControlsDelayed() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    _hideControlsTimer?.cancel();

    // 如果关闭了隐藏工具栏选项，始终保持显示
    if (!settings.hideToolbar) {
      if (!_showControls) {
        setState(() {
          _showControls = true;
        });
      }
      return;
    }

    // 根据设置的延迟时间自动隐藏
    _hideControlsTimer = Timer(
      Duration(seconds: settings.controlsHideDelay),
      _hideControlsIfIdle,
    );
  }

  void _hideInfoDelayed() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _hideInfoTimer?.cancel();
    if (settings.infoAutoHide) {
      _hideInfoTimer = Timer(
        Duration(seconds: settings.infoHideDelay),
        _hideInfoIfIdle,
      );
    }
  }

  /// 同 [_hideControlsIfIdle]：手势进行中不隐藏信息栏，
  /// 避免长按拖动时触发额外重建。
  void _hideInfoIfIdle() {
    if (!mounted || _isGestureActive || _pointerCount > 0) return;
    setState(() {
      _showInfo = false;
    });
  }

  /// 手指抬起：全部松开时结束手势状态。
  ///
  /// 若本次只是“轻点”（没有位移、没有捏合、也没触发切图），
  /// 就切换工具栏显隐——相当于把点击的切换逻辑
  /// 推迟到松手时，缩放时便不会弹出工具栏。
  void _handlePointerUp(PointerUpEvent event) {
    if (_pointerCount > 0) _pointerCount--;
    if (_pointerCount > 0) return;
    _pointerCount = 0;
    _onAllPointersReleased();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pointerCount > 0) _pointerCount--;
    if (_pointerCount > 0) return;
    _pointerCount = 0;
    _onAllPointersReleased();
  }

  /// 判断某个全局坐标点是否落在工具栏（顶部 AppBar / 底部按钮行 /
  /// 右下角缩放按钮）内。
  ///
  /// 用几何判定代替“在按钮之外再套一层 Listener 置标志位”：后者依赖
  /// 控件树中“按下/抬起”事件的先后顺序，一旦顺序变化就会失效；
  /// 而 [GlobalKey] + 命中矩形只取决于布局结果，与事件顺序无关。
  bool _isPointOnToolbar(Offset globalPosition) {
    for (final key in [_topControlsKey, _bottomControlsKey, _zoomControlsKey]) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(
        globalPosition,
      )) {
        return true;
      }
    }
    return false;
  }

  void _onAllPointersReleased() {
    _isGestureActive = false;
    // 取出本轮按下的落点后立即清空，避免影响下一次交互
    final downPosition = _pointerDownPosition;
    _pointerDownPosition = null;
    // 仅“单指轻点”才切换工具栏：
    // 双指捏合、有位移的拖动、靠泊切图都不会走到这里切换工具栏。
    final isSingleTap =
        !_gestureMoved &&
        !_gesturePinched &&
        !_suppressGestureUntilEnd &&
        !_multiPointerUsed;
    if (isSingleTap) {
      // 落在工具栏上的轻点属于“点按钮”，交给按钮自己的 onPressed 处理：
      // 只顺延自动隐藏计时，既不隐藏工具栏，也不取消自动播放计时器。
      // 注意不能用 _showControlsTemporarily()：那会把 _showInfo 也置为 true，
      // 让“点按钮”意外带出图片信息栏。
      if (downPosition != null && _isPointOnToolbar(downPosition)) {
        _hideControlsDelayed();
        _hideInfoDelayed();
        return;
      }
      // 轻点画面 → 切换工具栏显隐（显示中则立即关闭，已关闭则显示）
      _toggleControls();
    } else {
      // 缩放/拖动结束 → 重新开始自动隐藏计时
      _hideControlsDelayed();
      _hideInfoDelayed();
    }
  }

  /// 手势进行中把自动隐藏计时器顺延，而不是立刻弹出工具栏。
  ///
  /// 否则用户每次双指缩放都会让工具栏/信息栏闪现，
  /// 并且缩放手势本身会因多出来的重建而变得不流畅。
  /// 隐藏动作受 [_hideControlsIfIdle] 保护，手指按住期间不会生效。
  void _deferControlHide() {
    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  /// 只在手势确实已经结束（没有任何指针按下）时才隐藏工具栏。
  ///
  /// 缩放大图时用户可能连续多次捏合/拖动，中途松手又立刻按下，
  /// 这里必须避免在两次手势之间把工具栏隐藏掉再弹回来。
  void _hideControlsIfIdle() {
    if (!mounted || _isGestureActive || _pointerCount > 0) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (settings.keepControlsOnPause && !slideProvider.isPlaying) return;
    setState(() {
      _showControls = false;
    });
  }

  /// 显示工具栏与信息栏，并在超时后自动隐藏。
  ///
  /// 仅由真正的“点击”触发；按下瞬间不再弹出，避免缩放时工具栏闪现。
  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() {
      _showControls = true;
      _showInfo = true;
    });
    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  /// 轻点屏幕切换工具栏显隐。
  ///
  /// · 正在显示 → 立即关闭（无需等超时），同时取消待触发的隐藏计时器；
  /// · 已关闭   → 立刻显示并重新开始自动隐藏计时。
  ///
  /// 若用户在设置里关闭了“自动隐藏工具栏”，则工具栏应保持常显，
  /// 此时轻点不再关闭它（避免出现“关不掉又没超时可恢复”的困惑）。
  void _toggleControls() {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (_showControls && settings.hideToolbar) {
      _hideControlsTimer?.cancel();
      _hideInfoTimer?.cancel();
      setState(() {
        _showControls = false;
        _showInfo = false;
      });
      return;
    }
    _showControlsTemporarily();
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
    // 重启自动隐藏定时器
    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  // ==================== 缩放与平移 ====================

  /// 视口尺寸（由 [LayoutBuilder] 的实际布局尺寸得到）
  Size get _viewportSize {
    final cached = _viewportSizeCache;
    if (cached != null && !cached.isEmpty) return cached;
    final box = _gestureKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    return MediaQuery.sizeOf(context);
  }

  /// 视口中心（原点），手势焦点相对它换算，实现以指尖为锚点的缩放
  Offset get _viewportCenter => _viewportSize.center(Offset.zero);

  /// 当前是否处于放大状态
  bool get _isZoomed => _scale > 1.0 + _zoomEpsilon;

  /// 图片旋转后，在屏幕上占据的矩形尺寸（未缩放）
  ///
  /// 旋转 90°/270° 时宽高互换；角度先归一化到 (-π/2, π/2] 再计算，
  /// 避免按 3π/2 之类的等效角度算出负尺寸。
  Size _rotatedSize(Size logical, double rotation) {
    var angle = rotation % (2 * math.pi);
    if (angle < 0) angle += 2 * math.pi;
    angle = angle % math.pi;
    final swapped = (angle - math.pi / 2).abs() < 1e-6;
    return swapped ? Size(logical.height, logical.width) : logical;
  }

  /// 图片在屏幕上显示的实际尺寸（未缩放）。
  ///
  /// 图片用 `Transform(scale:)` 缩放，所以这里的返回值是“缩放前”的尺寸；
  /// 平移边界在 [_clamp] 里再乘以 [_scale]。
  Size _displayBaseSize(SettingsProvider settings) {
    final viewport = _viewportSize;
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return viewport;

    switch (settings.imageFitMode) {
      case ImageFitMode.contain:
        return _rotatedSize(
          applyBoxFit(BoxFit.contain, intrinsic, viewport).destination,
          _rotation + _autoRotation,
        );
      case ImageFitMode.cover:
        // cover 在未旋转时铺满视口，没有可平移的余量
        return _rotatedSize(
          applyBoxFit(BoxFit.cover, intrinsic, viewport).destination,
          _rotation + _autoRotation,
        );
      case ImageFitMode.original:
        // 原尺寸固定为图片像素尺寸，可平移余量可能很大
        return _rotatedSize(intrinsic, _rotation + _autoRotation);
    }
  }

  /// 某轴上的最大平移距离（0 表示该轴已铺满、无需平移）
  double _maxPanFor(double baseAxis, double viewportAxis, double scale) {
    final scaled = baseAxis * scale;
    if (scaled <= viewportAxis) return 0.0;
    return (scaled - viewportAxis) / 2;
  }

  /// 把平移量限制在图片边界内
  ///
  /// [scale] 显式传入，避免与即将写入的 _scale 不同步。
  Offset _clamp(Offset raw, SettingsProvider settings, double scale) {
    final viewport = _viewportSize;
    final base = _displayBaseSize(settings);
    final maxX = _maxPanFor(base.width, viewport.width, scale);
    final maxY = _maxPanFor(base.height, viewport.height, scale);
    return Offset(raw.dx.clamp(-maxX, maxX), raw.dy.clamp(-maxY, maxY));
  }

  /// 用当前缩放值夹紧平移量（供旋转、尺寸变化、手势结束等场景复用）
  Offset _clampCurrent(SettingsProvider settings) =>
      _clamp(_position, settings, _scale);

  void _handleScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startPosition = _position;
    _startFocal = details.localFocalPoint - _viewportCenter;
    _gestureTravel = 0.0;

    // 手势开始：标记进行中（挂起工具栏弹出），并重置停靠推进状态。
    // 注意：这里不重置 _gestureMoved/_gesturePinched ——
    // 框架在“双指→单指”时会通过 _reconfigure 重新派发 onStart，
    // 若在此重置会把已经发生的捏合“洗白”成轻点，导致松手时误弹工具栏。
    _isGestureActive = true;
    // 手指按住期间顺延自动隐藏计时，避免手势刚开始就被计时器弹出工具栏
    _deferControlHide();

    // 每次手势开始都重置停靠推进状态：
    // 停靠判定只在“单指·已放大”的拖拽过程中重新累积，
    // 否则双指捏合时的焦点位移会被误当成“继续向边缘拖拽”。
    _dockedEdge = 0;
    _dockAnchorX = 0.0;
    _suppressGestureUntilEnd = false;
    _gesturePinched = false;
    // 手势开始时基于当前缩放重新夹紧，保证起点合法
    _position = _clampCurrent(
      Provider.of<SettingsProvider>(context, listen: false),
    );
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    // 本次手势已触发切图（靠泊后继续拖出）：剩余事件全部忽略
    if (_suppressGestureUntilEnd) return;

    // 位移或缩放超过噪声阈值即视为“真实的缩放/拖动”，而非点击
    _gestureTravel = math.max(
      _gestureTravel,
      (details.localFocalPoint - _viewportCenter - _startFocal).distance,
    );
    if (_gestureTravel > _tapMoveSlop || (details.scale - 1.0).abs() >= 0.02) {
      _gestureMoved = true;
    }

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 换算成以视口中心为原点的坐标，缩放锚点计算会更直观
    final focal = details.localFocalPoint - _viewportCenter;

    // 1) 缩放：以手势焦点为锚点，使焦点下的像素在缩放前后保持不动
    final newScale = (_startScale * details.scale).clamp(_minScale, _maxScale);
    final ratio = _startScale == 0 ? 1.0 : newScale / _startScale;

    // 2) 平移：
    //    - 缩放带来的分量用 ratio 推导（锚点=焦点）
    //    - 指尖自身的位移（focal - _startFocal）直接叠加，
    //      这样单指拖动时 details.scale 恒为 1.0、ratio 为 1，
    //      平移量恰好等于手指位移，不会出现“拖动被缩放放大”的漂移。
    final drag = focal - _startFocal;
    final position = _startPosition * ratio + focal - _startFocal * ratio;

    // 记录本次手势是否真的做过捏合，供松手时区分滑动与缩放
    if ((details.scale - 1.0).abs() >= 0.02) _gesturePinched = true;

    final clamped = _clamp(position, settings, newScale);
    setState(() {
      _scale = newScale;
      _position = clamped;
    });

    // 3) 单指拖拽且已放大时，处理“靠泊→再次拖出切换图片”
    //    这里用 details.scale 是否恒为 1.0 来判断“本次没有捏合意图”，
    //    与双指缩放区分开，避免捏合时焦点位移被当成向边缘拖拽。
    final isSinglePointerDrag =
        details.pointerCount <= 1 && (details.scale - 1.0).abs() < 0.02;
    if (!isSinglePointerDrag || !_isZoomed) return;

    // 仅在横向意图明显时处理，避免竖向平移误触发切换
    if (drag.dx.abs() <= drag.dy.abs()) return;

    // 目标位置被 _clamp 挡住后多出来的部分就是“顶到边缘”的溢出量。
    // 用它的正负判定抵达的是哪一侧边缘，比比较 position/maxPan 更稳。
    final overshoot = position.dx - clamped.dx;
    if (overshoot.abs() < 0.5) {
      // 本次没有真正抵住边缘：撤销靠泊，等待下一次抵达
      _dockedEdge = 0;
      _dockAnchorX = 0.0;
      return;
    }

    final direction = overshoot > 0 ? 1 : -1;
    if (_dockedEdge != direction) {
      // 首次抵达该侧边缘：完成一次“靠泊”，以当前指尖位置为锚点。
      // 锚点取指尖位移（而非溢出量），这样快速甩动时也不会直接越过阈值。
      _dockedEdge = direction;
      _dockAnchorX = drag.dx;
      return;
    }

    // 已在边缘靠泊，继续向外推移超过阈值 → 切图
    //   direction > 0：向右推到底 → 上一张
    //   direction < 0：向左推到底 → 下一张
    final push = (drag.dx - _dockAnchorX) * direction;
    if (push < _dockPushThreshold) return;

    _dockedEdge = 0;
    _dockAnchorX = 0.0;
    _suppressGestureUntilEnd = true;
    if (direction > 0) {
      _prevImage();
    } else {
      _nextImage(manual: true);
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 注意：这两个标志必须在 setState 重置之前读出来
    final switchedInGesture = _suppressGestureUntilEnd; // 靠泊后已切过图
    final wasPinching = _gesturePinched;
    final wasZoomed = _isZoomed;

    setState(() {
      if (_scale <= _minScale + _zoomEpsilon) {
        _scale = _minScale;
        _position = Offset.zero;
      } else {
        // 手势结束时再夹紧一次，防止旋转或尺寸变化后残留越界
        _position = _clampCurrent(settings);
      }
      _dockedEdge = 0;
      _dockAnchorX = 0.0;
      _suppressGestureUntilEnd = false;
      _gesturePinched = false;
    });

    // 正在放大查看细节时不要自动切走，缩回原尺寸后再恢复自动播放
    if (_isZoomed) {
      _autoPlayTimer?.cancel();
      return;
    }
    if (wasZoomed) {
      _startAutoPlay();
      // 刚缩回原尺寸的这一次松手不再顺带切图，避免缩小时误翻页
      return;
    }

    // 以下情况不按速度切图：
    //  · 本次手势已经靠泊切过图（否则会一次动作连切两张）
    //  · 本次手势是捏合缩放（缩回时的焦点速度不具备翻页意图）
    if (switchedInGesture || wasPinching) return;

    // 未放大：按松手速度左右切换图片（等价于原来的横向拖拽手势）
    final velocity = details.velocity.pixelsPerSecond;
    if (velocity.dx.abs() <= velocity.dy.abs()) return; // 仅横向甩动才切图
    if (velocity.dx > _swipeVelocityThreshold) {
      _prevImage();
    } else if (velocity.dx < -_swipeVelocityThreshold) {
      _nextImage(manual: true);
    }
  }

  /// 为当前图片建立图片流监听，取得原始像素尺寸以计算平移边界
  void _updateIntrinsicSize(int index, String path) {
    if (_intrinsicSizeForIndex == index && _intrinsicSize != null) return;
    if (_intrinsicSizeForIndex == index) return; // 已发起过请求，等待回调

    _intrinsicSizeForIndex = index;
    _intrinsicSize = null;
    _detachIntrinsicSizeListener();

    // 关键：使用与 Image.file 完全相同的 provider（字节相同 → 缓存键相同），
    // 因此这里不会产生额外解码，只是复用已有的 ImageCache 条目。
    final provider = FileImage(File(path));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronousCall) {
        if (!mounted || _intrinsicSizeForIndex != index) return;
        setState(() {
          _intrinsicSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          // 尺寸拿到后按真实比例重新夹紧位置
          _position = _clampCurrent(
            Provider.of<SettingsProvider>(context, listen: false),
          );
          // 方向相关的自动旋转依赖图片尺寸，尺寸就绪后需要重算一次
          _updateOrientationRotation(
            Provider.of<SlideProvider>(context, listen: false),
            Provider.of<SettingsProvider>(context, listen: false),
          );
        });
      },
      onError: (error, stackTrace) {
        // 尺寸获取失败时保持未知，平移边界退化为“不可平移”
      },
    );
    _intrinsicListener = listener;

    final stream = provider.resolve(createLocalImageConfiguration(context));
    _intrinsicStream = stream;
    stream.addListener(listener);
  }

  void _detachIntrinsicSizeListener() {
    if (_intrinsicStream != null && _intrinsicListener != null) {
      _intrinsicStream!.removeListener(_intrinsicListener!);
    }
    _intrinsicStream = null;
    _intrinsicListener = null;
  }

  void _rotateImage() {
    setState(() {
      _rotation += math.pi / 2;
      // 旋转后图片占据的屏幕区域变了，原平移量可能已经越界
      _position = _clampCurrent(
        Provider.of<SettingsProvider>(context, listen: false),
      );
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
        // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
        if (Platform.isAndroid) {
          final images = await MediaStoreService.getFolderImages(folderPath);
          for (final item in images) {
            final dotIndex = item.path.lastIndexOf('.');
            if (dotIndex == -1) continue;
            final ext = item.path.toLowerCase().substring(dotIndex + 1);
            if (supportedExtensions.contains(ext)) {
              // 直接使用 MediaStore 返回的对象，保留已索引的宽高比
              uniqueImages.putIfAbsent(item.path, () => item);
            }
          }
        } else {
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
      slideProvider.stopPlay();
    }
    // 返回主界面
    Navigator.pop(context);
  }

  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is KeyDownEvent) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.space:
          _togglePlay();
          return true;
        case LogicalKeyboardKey.arrowLeft:
          _prevImage();
          return true;
        case LogicalKeyboardKey.arrowRight:
          _nextImage(manual: true);
          return true;
        case LogicalKeyboardKey.escape:
          // 全屏时按 ESC 退出全屏；非全屏时按 ESC 退出播放
          if (_isFullscreen) {
            _exitFullscreen();
          } else {
            _exitPlayback();
          }
          return true;
        case LogicalKeyboardKey.f11:
          if (_isFullscreen) {
            _exitFullscreen();
          } else {
            _enterFullscreen();
          }
          return true;
        case LogicalKeyboardKey.delete:
          _showDeleteConfirmation();
          return true;
        case LogicalKeyboardKey.keyR:
          _rescanImages();
          return true;
        default:
          break;
      }
    }
    return false;
  }

  void _handleScroll(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      if (settings.wheelSwitchImage) {
        // 滚轮切换图片（不触发工具栏显示）
        if (event.scrollDelta.dy > 0) {
          _nextImage(manual: true);
        } else if (event.scrollDelta.dy < 0) {
          _prevImage();
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

  /// 从缓存取文件大小文本；未缓存时返回占位符并触发异步加载。
  ///
  /// 切勿在 build 中直接读盘/解码，否则每次重建都会阻塞 UI 线程。
  String _fileSizeLabel(String path) {
    final cached = _fileSizeCache[path];
    if (cached != null) return cached;
    unawaited(_loadImageMeta(path));
    return '…';
  }

  /// 从缓存取分辨率文本；未缓存时返回占位符并触发异步加载。
  String _resolutionLabel(String path) {
    final cached = _resolutionCache[path];
    if (cached != null) return cached;
    unawaited(_loadImageMeta(path));
    return '…';
  }

  /// 只在磁盘上读取一次文件大小与图片分辨率，结果缓存起来。
  ///
  /// 解码放在后台 isolate（[compute]）中执行，避免阻塞手势帧。
  Future<void> _loadImageMeta(String path) async {
    if (_metaLoading.contains(path)) return;
    if (_fileSizeCache.containsKey(path) &&
        _resolutionCache.containsKey(path)) {
      return;
    }
    _metaLoading.add(path);
    try {
      final file = File(path);
      final sizeText = await _formatFileSize(file);
      final resolutionText = await _decodeResolution(file);
      if (!mounted) return;
      setState(() {
        _fileSizeCache[path] = sizeText;
        _resolutionCache[path] = resolutionText;
      });
    } finally {
      _metaLoading.remove(path);
    }
  }

  static Future<String> _formatFileSize(File file) async {
    try {
      final size = await file.length();
      if (size < 1024) return '$size B';
      if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '未知';
    }
  }

  static Future<String> _decodeResolution(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final size = await compute(_decodeImageSize, bytes);
      if (size == null) return '未知';
      return '${size.width} x ${size.height}';
    } catch (_) {
      return '未知';
    }
  }

  /// 根据图片方向设置，更新自动旋转角度
  ///
  /// 依赖 [_intrinsicSize]（由图片流回调异步填充），不再同步解码文件。
  void _updateOrientationRotation(
    SlideProvider slideProvider,
    SettingsProvider settings,
  ) {
    if (slideProvider.images.isEmpty) return;

    final imagePath = slideProvider.images[slideProvider.currentIndex].path;

    switch (settings.imageOrientation) {
      case ImageOrientation.landscape:
        // 强制横屏：如果图片是竖屏的，旋转90°
        _autoRotation = _isPortraitImage() ? math.pi / 2 : 0.0;
        break;
      case ImageOrientation.portrait:
        // 强制竖屏：如果图片是横屏的，旋转90°
        _autoRotation = _isLandscapeImage() ? math.pi / 2 : 0.0;
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

  /// 计算让图片长边对齐屏幕长边所需的旋转角度。
  ///
  /// 优先使用已缓存的原始尺寸（与缩放共用同一份数据），
  /// 避免在此处同步读盘+解码。
  double _getRotationToMatchScreen(String path) {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null || _intrinsicSizeForIndex != _lastProcessedIndex) {
      // 尺寸尚未就绪：先按不旋转处理，_updateIntrinsicSize 回调里会重新计算
      return 0.0;
    }

    final size = MediaQuery.of(context).size;
    final isScreenLandscape = size.width >= size.height;
    final isImageLandscape = intrinsic.width >= intrinsic.height;

    // 如果图片方向和屏幕方向不一致，旋转 90° 使长边对齐
    if (isScreenLandscape != isImageLandscape) {
      return math.pi / 2;
    }
    return 0.0;
  }

  bool _isPortraitImage() {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return false;
    return intrinsic.height > intrinsic.width;
  }

  bool _isLandscapeImage() {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return false;
    return intrinsic.width > intrinsic.height;
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
        // 检测设置变更并即时应用运行时效果（轮播间隔、方向、自动隐藏等）
        _applySettingsToPlayback(settings);

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
          // 同步当前图片的原始尺寸，用于计算缩放后的平移边界
          _updateIntrinsicSize(
            slideProvider.currentIndex,
            slideProvider.images[slideProvider.currentIndex].path,
          );
        }

        return Scaffold(
          backgroundColor: settings.background,
          body: Focus(
            autofocus: true,
            child: Listener(
              onPointerSignal: _handleScroll,
              // 用于“完全松手”才恢复工具栏：GestureDetector 的 onScaleEnd
              // 无法覆盖“双指后先抬一根手指、另一根继续停住”的情形。
              onPointerDown: (event) {
                if (_pointerCount == 0) {
                  // 新一轮交互开始，重置手势判定标志
                  // （点按按钮等情形不会走到 onScaleStart）
                  _gestureMoved = false;
                  _gesturePinched = false;
                  _suppressGestureUntilEnd = false;
                  _gestureTravel = 0.0;
                  _multiPointerUsed = false;
                  // 记下落点，松手时据此区分“点画面”与“点工具栏按钮”
                  _pointerDownPosition = event.position;
                }
                _pointerCount++;
                if (_pointerCount > 1) _multiPointerUsed = true;
              },
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: LayoutBuilder(
                // 图片以 Stack 铺满整个 body，因此用它的约束尺寸作为
                // 缩放/平移的视口尺寸，不再于 build 期间写入实例字段。
                builder: (context, constraints) {
                  // 仅在约束有限且非空时缓存；写入实例字段不会触发重建
                  final viewport = constraints.biggest;
                  if (viewport.isFinite && !viewport.isEmpty) {
                    _viewportSizeCache = viewport;
                  }
                  return GestureDetector(
                    key: _gestureKey,
                    behavior: HitTestBehavior.opaque,
                    // 注意：不要用 onTapDown 触发工具栏！
                    // onTapDown 在“手指刚按下”就会触发（即使随后变成缩放/拖动），
                    // 于是每次双指缩放都会弹出工具栏。
                    // 这里也不注册 onTap：统一由外层 Listener 在“所有手指抬起”时
                    // 判定本次是否只是轻点（见 _onAllPointersReleased）。
                    //
                    // 只注册缩放识别器、不注册横向拖拽识别器：
                    // 框架断言明确指出“scale 是 pan 的超集”，且拖拽的认定阈值
                    // （kTouchSlop 18）小于缩放的平移阈值（kPanSlop 36），
                    // 两者共存时单指拖动必被拖拽抢走、双指捏合也可能失效。
                    // 统一交给缩放识别器：
                    //   · 未放大 → 松手时按速度切图（见 _handleScaleEnd）
                    //   · 放大后 → 单指拖动平移 + 靠泊后继续推出切图
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
                            // 顺序很重要：Matrix4 的方法是在右侧相乘，
                            // 因此 M = T · S · R。平移在最外层，_position 才是
                            // 纯屏幕像素，与 [_clamp] 的边界计算保持一致；
                            // 若把 translate 写在最后（M = S · R · T），位移会被
                            // 缩放放大、被旋转转向，拖动会出现漂移。
                            transform: Matrix4.identity()
                              ..translateByVector3(
                                vector.Vector3(_position.dx, _position.dy, 0),
                              )
                              ..scaleByVector3(
                                vector.Vector3(_scale, _scale, _scale),
                              )
                              ..rotateZ(_rotation + _autoRotation),
                            child: SizedBox.expand(
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
                          ),
                          slideProvider.currentIndex,
                        ),
                        if (_showControls)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: AppBar(
                              key: _topControlsKey,
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.5,
                              ),
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
                                      final navigator = Navigator.of(context);
                                      // 延迟一小段时间让窗口状态稳定后再返回
                                      Future.delayed(
                                        const Duration(milliseconds: 200),
                                        () {
                                          if (mounted) navigator.pop();
                                        },
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
                                      settings.deleteAction ==
                                          DeleteAction.exclude
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
                                    onPressed: () => Navigator.pushNamed(
                                      context,
                                      '/settings',
                                    ),
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
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              slideProvider
                                                  .images[slideProvider
                                                      .currentIndex]
                                                  .name,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                color: Colors.white,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(width: 16),
                                            Text(
                                              _fileSizeLabel(
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
                                              _resolutionLabel(
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
                                    ),
                                  Row(
                                    key: _bottomControlsKey,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.skip_previous,
                                          size: 36,
                                        ),
                                        color: Colors.white,
                                        onPressed: () {
                                          _prevImage();
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
                                        icon: const Icon(
                                          Icons.skip_next,
                                          size: 36,
                                        ),
                                        color: Colors.white,
                                        onPressed: () {
                                          _nextImage(manual: true);
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
                            key: _zoomControlsKey,
                            children: [
                              if (_scale > _minScale)
                                FloatingActionButton(
                                  mini: true,
                                  onPressed: () => setState(() {
                                    _scale = _minScale;
                                    _position = Offset.zero;
                                    _dockedEdge = 0;
                                    _dockAnchorX = 0.0;
                                  }),
                                  child: const Icon(Icons.zoom_out),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
