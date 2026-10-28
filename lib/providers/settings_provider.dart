import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frame_flow/models/lan_models.dart';

/// 播放顺序
///
/// 新增项必须追加在末尾：该枚举按下标持久化到 SharedPreferences，
/// 插在中间会让老用户已保存的下标含义错位。
enum PlayOrder {
  sequential,
  random,
  newestFirst,
  oldestFirst,
  newPreferred,
  reverseSequential, // 逆序播放（按文件名降序）
  sizeLargest, // 由大到小（按文件大小降序）
  sizeSmallest, // 由小到大（按文件大小升序）
}

enum ImageFitMode { contain, cover, original }

enum BackgroundColor { black, darkGray, white }

enum TransitionAnimation { none, fade, slideLeft, slideUp }

enum DeleteAction {
  exclude, // 排除播放
  delete, // 实际删除
}

enum ImageOrientation {
  landscape, // 横屏
  portrait, // 竖屏
  followSystem, // 跟随系统
  followImage, // 跟随图片
}

/// 手机端瀑布流卡片的短按行为。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum MobileTapAction {
  play, // 短按直接播放，长按选中
  select, // 短按选中，长按或再次短按播放
}

/// 瀑布流卡片下方展示的文件信息（单选）。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum FileListInfo {
  none, // 不显示
  name, // 文件名
  nameDateSize, // 文件名 + 日期 + 大小
}

/// 图片浏览格式（瀑布流或固定画幅）。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum BrowseLayout {
  masonry, // 瀑布流（按图片原始比例）
  square, // 正方形
  landscape4x3, // 横屏 4:3
  landscape16x9, // 横屏 16:9
  portrait3x4, // 竖屏 3:4
  portrait9x16, // 竖屏 9:16
}

extension BrowseLayoutAspect on BrowseLayout {
  /// 固定画幅的宽高比；瀑布流返回 null，表示沿用图片自身比例
  double? get aspectRatio => switch (this) {
    BrowseLayout.masonry => null,
    BrowseLayout.square => 1.0,
    BrowseLayout.landscape4x3 => 4 / 3,
    BrowseLayout.landscape16x9 => 16 / 9,
    BrowseLayout.portrait3x4 => 3 / 4,
    BrowseLayout.portrait9x16 => 9 / 16,
  };
}

class SettingsProvider extends ChangeNotifier {
  // 播放基础设置
  // 换片时间的滑块档位值（毫秒），自定义开关关闭时生效
  int _interval = 4000;
  PlayOrder _playOrder = PlayOrder.newPreferred;
  bool _loopPlay = false;
  bool _autoPlay = true;

  // 图片显示设置
  ImageFitMode _imageFitMode = ImageFitMode.contain;
  BackgroundColor _backgroundColor = BackgroundColor.black;
  ImageOrientation _imageOrientation = ImageOrientation.followSystem;

  // 切换动画
  TransitionAnimation _transitionAnimation = TransitionAnimation.fade;
  double _animationDuration = 0.5;

  // 窗口/全屏控制
  bool _startFullscreen = true;
  bool _hideToolbar = true;
  int _controlsHideDelay = 3;
  bool _keepControlsOnPause = false;

  // 文件与目录相关
  bool _recursiveScan = true;
  FileListInfo _fileListInfo = FileListInfo.none;
  BrowseLayout _browseLayout = BrowseLayout.masonry;

  /// 本地文件夹的浏览格式（路径 → 格式 id），未记录时跟随设置页默认值
  Map<String, String> _localBrowseLayouts = {};

  /// 共享文件夹的浏览格式（共享文件夹 key → 格式 id）
  Map<String, String> _sharedBrowseLayouts = {};

  // 桌面端窗口行为：关闭按钮是否收起到系统托盘
  bool _closeToTray = false;

  String? _lastFolderPath;
  List<String> _lastFolderPaths = [];

  // 信息显示设置（自动隐藏由工具栏的自动隐藏设置统一控制）
  bool _showImageInfo = false;

  // 快捷键与控制
  bool _wheelSwitchImage = true;

  /// 手机端短按卡片的行为（默认选中）
  MobileTapAction _mobileTapAction = MobileTapAction.select;

  /// Windows 端是否在支持的图片格式上注册「用 FrameFlow 打开」右键菜单
  bool _addToContextMenu = false;

  // 删除行为设置
  DeleteAction _deleteAction = DeleteAction.exclude;
  List<String> _excludedPaths = [];

  /// 本地文件夹的瀑布流排序方式（路径 → 排序 id）
  Map<String, String> _localSortModes = {};

  /// 共享文件夹的瀑布流排序方式（共享文件夹 key → 排序 id）
  Map<String, String> _sharedSortModes = {};

  /// 上次复制文件时使用的目标目录（Android 为 SAF URI，桌面为本地路径）
  String? _lastCopyDestination;

  // 语言设置（0=跟随系统, 1=简体中文, 2=English, 3=繁體中文）
  int _languageIndex = 0;

  // 自定义换片时间（毫秒），默认1800秒 = 1800000ms，开关打开时生效
  int _customInterval = 1800000;

  // 是否启用自定义换片时间：开启时 _customInterval 生效，_interval 仅保留滑块位置
  bool _useCustomInterval = false;

  // 局域网共享
  bool _lanShareEnabled = false;

  /// 是否允许其他终端远程排除本机共享文件夹中的图片（仅排除播放，不删除文件）
  bool _allowRemoteExclude = false;

  /// 是否允许其他终端复制本机共享文件夹中的图片
  bool _allowRemoteCopy = false;

  /// 本地文件夹是否共享给其他设备的单独开关（缺省视为共享）
  Map<String, bool> _lanFolderSharing = {};

  /// 本机添加的共享文件夹（来自其他设备，作为播放源）
  List<SharedFolderRef> _sharedFolders = [];

  /// 本机唯一标识，首次启动时生成并持久化，用于在发现列表中排除自己
  String _deviceId = '';

  /// 本机在局域网中显示的名称（Android 上为厂商 + 型号）
  String _deviceName = _fallbackDeviceName();

  /// 换片时间的生效值：自定义开关开启时取自定义秒数，否则取滑块档位值
  int get interval => _useCustomInterval ? _customInterval : _interval;

  /// 滑块档位值（自定义开启时仅保留位置，不参与生效）
  int get presetInterval => _interval;
  int get customInterval => _customInterval;
  bool get useCustomInterval => _useCustomInterval;
  List<String> get excludedPaths => List.unmodifiable(_excludedPaths);

  /// 读取某个本地文件夹上次使用的排序方式；未记录时返回 null（默认顺序）
  String? localSortFor(String folderPath) => _localSortModes[folderPath];

  /// 读取某个共享文件夹上次使用的排序方式；未记录时返回 null（默认顺序）
  String? sharedSortFor(String folderKey) => _sharedSortModes[folderKey];

  /// 读取某个本地文件夹上次使用的浏览格式；未记录时返回 null（跟随设置页）
  String? localBrowseLayoutFor(String folderPath) =>
      _localBrowseLayouts[folderPath];

  /// 读取某个共享文件夹上次使用的浏览格式；未记录时返回 null（跟随设置页）
  String? sharedBrowseLayoutFor(String folderKey) =>
      _sharedBrowseLayouts[folderKey];

  /// 上次复制文件的目标目录
  String? get lastCopyDestination => _lastCopyDestination;
  PlayOrder get playOrder => _playOrder;
  bool get loopPlay => _loopPlay;
  bool get autoPlay => _autoPlay;
  ImageFitMode get imageFitMode => _imageFitMode;
  BackgroundColor get backgroundColor => _backgroundColor;
  ImageOrientation get imageOrientation => _imageOrientation;
  TransitionAnimation get transitionAnimation => _transitionAnimation;
  double get animationDuration => _animationDuration;
  bool get startFullscreen => _startFullscreen;
  bool get hideToolbar => _hideToolbar;
  int get controlsHideDelay => _controlsHideDelay;
  bool get keepControlsOnPause => _keepControlsOnPause;
  bool get recursiveScan => _recursiveScan;
  FileListInfo get fileListInfo => _fileListInfo;
  BrowseLayout get browseLayout => _browseLayout;
  bool get closeToTray => _closeToTray;

  String? get lastFolderPath => _lastFolderPath;
  List<String> get lastFolderPaths => _lastFolderPaths;

  bool get showImageInfo => _showImageInfo;
  bool get wheelSwitchImage => _wheelSwitchImage;

  /// 手机端短按卡片的行为
  MobileTapAction get mobileTapAction => _mobileTapAction;

  /// 是否已启用「用 FrameFlow 打开」右键菜单
  bool get addToContextMenu => _addToContextMenu;
  DeleteAction get deleteAction => _deleteAction;
  int get languageIndex => _languageIndex;

  /// 是否允许局域网内其他设备浏览/播放本机共享的图片
  bool get lanShareEnabled => _lanShareEnabled;

  /// 是否允许其他终端远程排除播放本机共享文件夹中的图片
  bool get allowRemoteExclude => _allowRemoteExclude;

  /// 是否允许其他终端复制本机共享文件夹中的图片
  bool get allowRemoteCopy => _allowRemoteCopy;

  /// 各本地文件夹的共享开关（未记录的文件夹缺省为共享）
  Map<String, bool> get lanFolderSharing => Map.unmodifiable(_lanFolderSharing);

  bool isLocalFolderShared(String path) => _lanFolderSharing[path] ?? true;

  /// 已添加的共享文件夹（其他设备上的目录）
  List<SharedFolderRef> get sharedFolders => List.unmodifiable(_sharedFolders);

  /// 本机设备标识（持久化，用于发现列表中排除自己）
  String get deviceId => _deviceId;

  /// 本机在局域网中显示的名称
  String get deviceName => _deviceName;

  static String _fallbackDeviceName() {
    final host = Platform.localHostname.trim();
    if (host.isEmpty || host == 'localhost') return 'FrameFlow';
    return host;
  }

  // Setters
  void setPresetInterval(int value) {
    _interval = value;
    notifyListeners();
    _saveSettings();
  }

  void setUseCustomInterval(bool value) {
    _useCustomInterval = value;
    notifyListeners();
    _saveSettings();
  }

  void setPlayOrder(PlayOrder value) {
    _playOrder = value;
    notifyListeners();
    _saveSettings();
  }

  void setLoopPlay(bool value) {
    _loopPlay = value;
    notifyListeners();
    _saveSettings();
  }

  void setAutoPlay(bool value) {
    _autoPlay = value;
    notifyListeners();
    _saveSettings();
  }

  void setImageFitMode(ImageFitMode value) {
    _imageFitMode = value;
    notifyListeners();
    _saveSettings();
  }

  void setBackgroundColor(BackgroundColor value) {
    _backgroundColor = value;
    notifyListeners();
    _saveSettings();
  }

  void setImageOrientation(ImageOrientation value) {
    _imageOrientation = value;
    notifyListeners();
    _saveSettings();
  }

  void setTransitionAnimation(TransitionAnimation value) {
    _transitionAnimation = value;
    notifyListeners();
    _saveSettings();
  }

  void setAnimationDuration(double value) {
    _animationDuration = value;
    notifyListeners();
    _saveSettings();
  }

  void setStartFullscreen(bool value) {
    _startFullscreen = value;
    notifyListeners();
    _saveSettings();
  }

  void setHideToolbar(bool value) {
    _hideToolbar = value;
    notifyListeners();
    _saveSettings();
  }

  void setControlsHideDelay(int value) {
    _controlsHideDelay = value;
    notifyListeners();
    _saveSettings();
  }

  void setKeepControlsOnPause(bool value) {
    _keepControlsOnPause = value;
    notifyListeners();
    _saveSettings();
  }

  void setRecursiveScan(bool value) {
    _recursiveScan = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置瀑布流卡片下方展示的文件信息（单选）。
  void setFileListInfo(FileListInfo value) {
    _fileListInfo = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置默认的浏览格式（单个文件夹未单独设置时使用）
  void setBrowseLayout(BrowseLayout value) {
    if (_browseLayout == value) return;
    _browseLayout = value;
    notifyListeners();
    _saveSettings();
  }

  void setCloseToTray(bool value) {
    _closeToTray = value;
    notifyListeners();
    _saveSettings();
  }

  void setLastFolderPath(String? value) {
    _lastFolderPath = value;
    notifyListeners();
    _saveSettings();
  }

  void setLastFolderPaths(List<String> value) {
    _lastFolderPaths = value;
    notifyListeners();
    _saveSettings();
  }

  void setShowImageInfo(bool value) {
    _showImageInfo = value;
    notifyListeners();
    _saveSettings();
  }

  void setWheelSwitchImage(bool value) {
    _wheelSwitchImage = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置手机端短按卡片的行为
  void setMobileTapAction(MobileTapAction value) {
    if (_mobileTapAction == value) return;
    _mobileTapAction = value;
    notifyListeners();
    _saveSettings();
  }

  /// 记录右键菜单集成是否已启用（实际注册由设置页调用系统服务完成）
  void setAddToContextMenu(bool value) {
    if (_addToContextMenu == value) return;
    _addToContextMenu = value;
    notifyListeners();
    _saveSettings();
  }

  void setDeleteAction(DeleteAction value) {
    _deleteAction = value;
    notifyListeners();
    _saveSettings();
  }

  void setLanguageIndex(int value) {
    _languageIndex = value;
    notifyListeners();
    _saveSettings();
  }

  void setLanShareEnabled(bool value) {
    if (_lanShareEnabled == value) return;
    _lanShareEnabled = value;
    notifyListeners();
    _saveSettings();
  }

  void setAllowRemoteExclude(bool value) {
    if (_allowRemoteExclude == value) return;
    _allowRemoteExclude = value;
    notifyListeners();
    _saveSettings();
  }

  void setAllowRemoteCopy(bool value) {
    if (_allowRemoteCopy == value) return;
    _allowRemoteCopy = value;
    notifyListeners();
    _saveSettings();
  }

  void setLocalFolderShared(String path, bool value) {
    if ((_lanFolderSharing[path] ?? true) == value) return;
    _lanFolderSharing[path] = value;
    notifyListeners();
    _saveSettings();
  }

  /// 批量设置文件夹共享状态（切换整体共享开关时同步下方各文件夹开关）
  ///
  /// 合并为一次通知与一次落盘，避免逐个文件夹触发重建。
  void setAllLocalFoldersShared(Iterable<String> paths, bool value) {
    var changed = false;
    for (final path in paths) {
      if ((_lanFolderSharing[path] ?? true) != value) {
        _lanFolderSharing[path] = value;
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    _saveSettings();
  }

  void addSharedFolder(SharedFolderRef ref) {
    _sharedFolders.removeWhere((item) => item.key == ref.key);
    _sharedFolders.add(ref);
    notifyListeners();
    _saveSettings();
  }

  void removeSharedFolder(String key) {
    final before = _sharedFolders.length;
    _sharedFolders.removeWhere((item) => item.key == key);
    if (_sharedFolders.length == before) return;
    notifyListeners();
    _saveSettings();
  }

  /// 用最新的连接信息替换同一条共享文件夹记录
  void updateSharedFolder(SharedFolderRef ref) {
    final index = _sharedFolders.indexWhere((item) => item.key == ref.key);
    if (index < 0) return;
    final current = _sharedFolders[index];
    if (current.deviceName == ref.deviceName &&
        current.host == ref.host &&
        current.port == ref.port &&
        current.folderName == ref.folderName &&
        current.imageCount == ref.imageCount) {
      return;
    }
    _sharedFolders[index] = ref;
    notifyListeners();
    _saveSettings();
  }

  void clearSharedFolders() {
    if (_sharedFolders.isEmpty) return;
    _sharedFolders.clear();
    notifyListeners();
    _saveSettings();
  }

  void setCustomInterval(int value) {
    _customInterval = value;
    notifyListeners();
    _saveSettings();
  }

  void addExcludedPath(String path) {
    if (!_excludedPaths.contains(path)) {
      _excludedPaths.add(path);
      notifyListeners();
      _saveSettings();
    }
  }

  void removeExcludedPath(String path) {
    final before = _excludedPaths.length;
    // 历史数据里可能存在重复路径，这里一次性全部移除
    _excludedPaths.removeWhere((item) => item == path);
    if (_excludedPaths.length == before) return;
    notifyListeners();
    _saveSettings();
  }

  void clearExcludedPaths() {
    _excludedPaths.clear();
    notifyListeners();
    _saveSettings();
  }

  /// 批量移除已排除路径，只触发一次通知与保存
  void removeExcludedPaths(Iterable<String> paths) {
    final targets = paths.toSet();
    if (targets.isEmpty) return;
    final before = _excludedPaths.length;
    _excludedPaths.removeWhere(targets.contains);
    if (_excludedPaths.length == before) return;
    notifyListeners();
    _saveSettings();
  }

  /// 记住某个本地文件夹的瀑布流排序方式
  void setLocalSort(String folderPath, String sortId) {
    if (_localSortModes[folderPath] == sortId) return;
    _localSortModes[folderPath] = sortId;
    _saveSettings();
  }

  /// 记住某个共享文件夹的瀑布流排序方式
  void setSharedSort(String folderKey, String sortId) {
    if (_sharedSortModes[folderKey] == sortId) return;
    _sharedSortModes[folderKey] = sortId;
    _saveSettings();
  }

  /// 记住某个本地文件夹的浏览格式
  void setLocalBrowseLayout(String folderPath, BrowseLayout layout) {
    if (_localBrowseLayouts[folderPath] == layout.name) return;
    _localBrowseLayouts[folderPath] = layout.name;
    _saveSettings();
  }

  /// 记住某个共享文件夹的浏览格式
  void setSharedBrowseLayout(String folderKey, BrowseLayout layout) {
    if (_sharedBrowseLayouts[folderKey] == layout.name) return;
    _sharedBrowseLayouts[folderKey] = layout.name;
    _saveSettings();
  }

  /// 把持久化的浏览格式 id 还原为枚举；未知 id 返回 null
  static BrowseLayout? parseBrowseLayout(String? id) {
    if (id == null) return null;
    for (final layout in BrowseLayout.values) {
      if (layout.name == id) return layout;
    }
    return null;
  }

  /// 记住上次复制文件的目标目录
  void setLastCopyDestination(String destination) {
    if (_lastCopyDestination == destination) return;
    _lastCopyDestination = destination;
    _saveSettings();
  }

  // 获取BoxFit枚举
  BoxFit get boxFit {
    switch (_imageFitMode) {
      case ImageFitMode.contain:
        return BoxFit.contain;
      case ImageFitMode.cover:
        return BoxFit.cover;
      case ImageFitMode.original:
        return BoxFit.none;
    }
  }

  // 获取背景颜色
  Color get background {
    switch (_backgroundColor) {
      case BackgroundColor.black:
        return Colors.black;
      case BackgroundColor.darkGray:
        return const Color(0xFF333333);
      case BackgroundColor.white:
        return Colors.white;
    }
  }

  // 加载设置
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _interval = prefs.getInt('interval') ?? 4000;
    _playOrder = PlayOrder
        .values[prefs.getInt('playOrder') ?? PlayOrder.newPreferred.index];
    _loopPlay = prefs.getBool('loopPlay') ?? false;
    _autoPlay = prefs.getBool('autoPlay') ?? true;
    _imageFitMode = ImageFitMode.values[prefs.getInt('imageFitMode') ?? 0];
    _backgroundColor =
        BackgroundColor.values[prefs.getInt('backgroundColor') ?? 0];
    // 下标做边界保护：旧版本枚举里还有 slideRight/slideDown，
    // 若用户存过越界下标，直接取值会 RangeError 导致启动崩溃
    final animationIndex = (prefs.getInt('transitionAnimation') ?? 1).clamp(
      0,
      TransitionAnimation.values.length - 1,
    );
    _transitionAnimation = TransitionAnimation.values[animationIndex];
    _animationDuration = prefs.getDouble('animationDuration') ?? 0.5;
    _startFullscreen = prefs.getBool('startFullscreen') ?? true;
    _hideToolbar = prefs.getBool('hideToolbar') ?? true;
    _controlsHideDelay = prefs.getInt('controlsHideDelay') ?? 3;
    _keepControlsOnPause = prefs.getBool('keepControlsOnPause') ?? false;
    _recursiveScan = prefs.getBool('recursiveScan') ?? true;
    final fileListInfoIndex = (prefs.getInt('fileListInfoMode') ?? 0).clamp(
      0,
      FileListInfo.values.length - 1,
    );
    _fileListInfo = FileListInfo.values[fileListInfoIndex];
    final browseLayoutIndex = (prefs.getInt('browseLayout') ?? 0).clamp(
      0,
      BrowseLayout.values.length - 1,
    );
    _browseLayout = BrowseLayout.values[browseLayoutIndex];
    _closeToTray = prefs.getBool('closeToTray') ?? false;

    _lastFolderPath = prefs.getString('lastFolderPath');
    final lastFolderPathsStr = prefs.getString('lastFolderPaths');
    if (lastFolderPathsStr != null) {
      _lastFolderPaths = json.decode(lastFolderPathsStr).cast<String>();
    }
    _showImageInfo = prefs.getBool('showImageInfo') ?? false;

    final excludedStr = prefs.getString('excludedPaths');
    if (excludedStr != null) {
      // 去掉历史数据中的重复路径，避免已排除统计翻倍
      _excludedPaths = json.decode(excludedStr).cast<String>().toSet().toList();
    }

    _localSortModes = _decodeStringMap(prefs.getString('localSortModes'));
    _sharedSortModes = _decodeStringMap(prefs.getString('sharedSortModes'));
    _localBrowseLayouts = _decodeStringMap(
      prefs.getString('localBrowseLayouts'),
    );
    _sharedBrowseLayouts = _decodeStringMap(
      prefs.getString('sharedBrowseLayouts'),
    );
    _lastCopyDestination = prefs.getString('lastCopyDestination');

    _wheelSwitchImage = prefs.getBool('wheelSwitchImage') ?? true;
    final mobileTapIndex =
        (prefs.getInt('mobileTapAction') ?? MobileTapAction.select.index).clamp(
          0,
          MobileTapAction.values.length - 1,
        );
    _mobileTapAction = MobileTapAction.values[mobileTapIndex];
    _addToContextMenu = prefs.getBool('addToContextMenu') ?? false;
    _deleteAction = DeleteAction.values[prefs.getInt('deleteAction') ?? 0];
    _imageOrientation =
        ImageOrientation.values[prefs.getInt('imageOrientation') ?? 2];
    _languageIndex = prefs.getInt('languageIndex') ?? 0;
    _customInterval = prefs.getInt('customInterval') ?? 1800000;
    _useCustomInterval = prefs.getBool('useCustomInterval') ?? false;

    _lanShareEnabled = prefs.getBool('lanShareEnabled') ?? false;
    _allowRemoteExclude = prefs.getBool('allowRemoteExclude') ?? false;
    _allowRemoteCopy = prefs.getBool('allowRemoteCopy') ?? false;
    _lanFolderSharing = {};
    final lanFolderSharingStr = prefs.getString('lanFolderSharing');
    if (lanFolderSharingStr != null) {
      try {
        final decoded = json.decode(lanFolderSharingStr);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is bool) {
              _lanFolderSharing[entry.key as String] = entry.value as bool;
            }
          }
        }
      } catch (_) {
        // 数据损坏时退回默认值（全部共享）
      }
    }
    _sharedFolders = [];
    final sharedFoldersStr = prefs.getString('sharedFolders');
    if (sharedFoldersStr != null) {
      try {
        final decoded = json.decode(sharedFoldersStr);
        if (decoded is List) {
          for (final entry in decoded) {
            final ref = SharedFolderRef.fromJson(entry);
            if (ref != null && !_sharedFolders.any((e) => e.key == ref.key)) {
              _sharedFolders.add(ref);
            }
          }
        }
      } catch (_) {
        // 数据损坏时忽略已添加的共享文件夹
      }
    }
    _deviceId = prefs.getString('deviceId') ?? '';
    if (_deviceId.isEmpty) {
      _deviceId = _generateDeviceId();
      await prefs.setString('deviceId', _deviceId);
    }

    await _resolveDeviceName();
    notifyListeners();
  }

  /// 读取真实设备名。
  ///
  /// Android 的 [Platform.localHostname] 通常只返回 localhost，
  /// 这里改用系统提供的厂商与型号，便于在局域网设备列表中区分不同手机。
  Future<void> _resolveDeviceName() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final model = info.model.trim();
      if (model.isEmpty) return;
      final manufacturer = info.manufacturer.trim();
      if (manufacturer.isEmpty ||
          model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
        _deviceName = model;
      } else {
        _deviceName = '$manufacturer $model';
      }
    } catch (_) {
      // 读取失败时保留默认名称
    }
  }

  /// 解析存储为 JSON 的「字符串 → 字符串」映射，数据损坏时返回空表
  static Map<String, String> _decodeStringMap(String? raw) {
    if (raw == null) return {};
    try {
      final decoded = json.decode(raw);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        };
      }
    } catch (_) {
      // 数据损坏时退回空表
    }
    return {};
  }

  /// 生成一个进程无关的稳定设备标识（基 36 时间戳 + 随机数）
  static String _generateDeviceId() {
    final random = Random.secure();
    final suffix = random.nextInt(0x7fffffff).toRadixString(36);
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}$suffix';
  }

  // 保存设置
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('interval', _interval);
    await prefs.setInt('playOrder', _playOrder.index);
    await prefs.setBool('loopPlay', _loopPlay);
    await prefs.setBool('autoPlay', _autoPlay);
    await prefs.setInt('imageFitMode', _imageFitMode.index);
    await prefs.setInt('backgroundColor', _backgroundColor.index);
    await prefs.setInt('transitionAnimation', _transitionAnimation.index);
    await prefs.setDouble('animationDuration', _animationDuration);
    await prefs.setBool('startFullscreen', _startFullscreen);
    await prefs.setBool('hideToolbar', _hideToolbar);
    await prefs.setInt('controlsHideDelay', _controlsHideDelay);
    await prefs.setBool('keepControlsOnPause', _keepControlsOnPause);
    await prefs.setBool('recursiveScan', _recursiveScan);
    await prefs.setInt('fileListInfoMode', _fileListInfo.index);
    await prefs.setInt('browseLayout', _browseLayout.index);
    await prefs.setBool('closeToTray', _closeToTray);

    await prefs.setString('lastFolderPath', _lastFolderPath ?? '');
    await prefs.setString('lastFolderPaths', json.encode(_lastFolderPaths));
    await prefs.setInt('deleteAction', _deleteAction.index);
    await prefs.setBool('showImageInfo', _showImageInfo);
    await prefs.setInt('languageIndex', _languageIndex);
    await prefs.setInt('customInterval', _customInterval);
    await prefs.setBool('useCustomInterval', _useCustomInterval);
    await prefs.setBool('wheelSwitchImage', _wheelSwitchImage);
    await prefs.setInt('mobileTapAction', _mobileTapAction.index);
    await prefs.setBool('addToContextMenu', _addToContextMenu);
    await prefs.setString('excludedPaths', json.encode(_excludedPaths));
    await prefs.setString('localSortModes', json.encode(_localSortModes));
    await prefs.setString('sharedSortModes', json.encode(_sharedSortModes));
    await prefs.setString(
      'localBrowseLayouts',
      json.encode(_localBrowseLayouts),
    );
    await prefs.setString(
      'sharedBrowseLayouts',
      json.encode(_sharedBrowseLayouts),
    );
    if (_lastCopyDestination != null) {
      await prefs.setString('lastCopyDestination', _lastCopyDestination!);
    } else {
      await prefs.remove('lastCopyDestination');
    }
    await prefs.setInt('imageOrientation', _imageOrientation.index);
    await prefs.setBool('lanShareEnabled', _lanShareEnabled);
    await prefs.setBool('allowRemoteExclude', _allowRemoteExclude);
    await prefs.setBool('allowRemoteCopy', _allowRemoteCopy);
    await prefs.setString('lanFolderSharing', json.encode(_lanFolderSharing));
    await prefs.setString(
      'sharedFolders',
      json.encode(_sharedFolders.map((item) => item.toJson()).toList()),
    );
    await prefs.setString('deviceId', _deviceId);
  }
}
