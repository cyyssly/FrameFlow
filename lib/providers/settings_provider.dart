import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frame_flow/l10n/app_localizations.dart';
import 'package:frame_flow/models/image_library.dart';
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

  /// 所有图片库（互不关联的文件夹集合）
  List<ImageLibrary> _libraries = [];

  /// 当前激活的库 id
  String _activeLibraryId = '';

  /// 库列表是否显示已隐藏的库（开启时半透明展示，关闭时完全隐藏）
  bool _showHiddenLibraries = false;

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

  /// 当前激活库排除播放的图片路径；无库时回退到全局列表（迁移期兼容）
  List<String> get excludedPaths {
    final lib = activeLibrary;
    return List.unmodifiable(lib?.excludedPaths ?? _excludedPaths);
  }

  /// 所有库排除路径的并集。
  ///
  /// 局域网共享时对外提供本机文件夹，被排除的图片可能与当前激活库无关，
  /// 因此服务端要用并集，避免在其他库里排除的图片又出现在共享列表里。
  List<String> get allExcludedPaths {
    final union = <String>{..._excludedPaths};
    for (final lib in _libraries) {
      union.addAll(lib.excludedPaths);
    }
    return List.unmodifiable(union.toList());
  }

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

  /// 当前激活库的文件夹列表；无库时回退到 [_lastFolderPaths]（迁移期兼容）。
  ///
  /// 现有所有代码都通过它读取「当前管理的文件夹」，因此引入多库后无需改动。
  List<String> get lastFolderPaths {
    final lib = activeLibrary;
    return lib != null ? lib.folderPaths : _lastFolderPaths;
  }

  /// 全部库（只读视图）
  List<ImageLibrary> get libraries => List.unmodifiable(_libraries);

  String get activeLibraryId => _activeLibraryId;

  /// 库列表是否显示已隐藏的库
  bool get showHiddenLibraries => _showHiddenLibraries;

  /// 当前激活的库；无库时返回 null
  ImageLibrary? get activeLibrary {
    for (final lib in _libraries) {
      if (lib.id == _activeLibraryId) return lib;
    }
    return _libraries.isNotEmpty ? _libraries.first : null;
  }

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

  /// 当前激活库绑定的共享文件夹（按全局登记顺序）
  ///
  /// 无库时返回全部（迁移期兼容）。
  List<SharedFolderRef> get activeLibrarySharedFolders {
    final lib = activeLibrary;
    if (lib == null) return List.unmodifiable(_sharedFolders);
    final keys = lib.sharedFolderKeys.toSet();
    return List.unmodifiable([
      for (final ref in _sharedFolders)
        if (keys.contains(ref.key)) ref,
    ]);
  }

  /// 某个共享源是否已绑定到当前激活库
  bool isSharedFolderInActiveLibrary(String key) {
    final lib = activeLibrary;
    if (lib == null) return _sharedFolders.any((ref) => ref.key == key);
    return lib.sharedFolderKeys.contains(key);
  }

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
    final copy = List<String>.of(value);
    _lastFolderPaths = copy;
    // 还没有库时自动建立默认库，保证新添加的文件夹有库可归属
    _ensureActiveLibrary().folderPaths = copy;
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

  /// 添加共享文件夹，并绑定到当前激活的库。
  ///
  /// 同一个共享源可以被多个库分别绑定：再次添加时只更新全局登记信息，
  /// 并确保当前库已包含该绑定。
  void addSharedFolder(SharedFolderRef ref) {
    _sharedFolders.removeWhere((item) => item.key == ref.key);
    _sharedFolders.add(ref);
    // 还没有库时自动建立默认库，保证共享源有库可绑定
    final lib = _ensureActiveLibrary();
    if (!lib.sharedFolderKeys.contains(ref.key)) {
      lib.sharedFolderKeys.add(ref.key);
    }
    notifyListeners();
    _saveSettings();
  }

  /// 把共享文件夹从当前激活库解绑。
  ///
  /// 若已没有任何库绑定该共享源，则连同全局登记一起清除。
  void removeSharedFolderFromActiveLibrary(String key) {
    final lib = activeLibrary;
    if (lib == null) return;
    final before = lib.sharedFolderKeys.length;
    lib.sharedFolderKeys.removeWhere((item) => item == key);
    if (lib.sharedFolderKeys.length == before) return;
    _pruneUnusedSharedFolders();
    notifyListeners();
    _saveSettings();
  }

  /// 清除没有被任何库引用的共享源登记，避免继续探测与缓存无用源
  void _pruneUnusedSharedFolders() {
    final used = <String>{
      for (final lib in _libraries) ...lib.sharedFolderKeys,
    };
    _sharedFolders.removeWhere((ref) => !used.contains(ref.key));
  }

  // ── 多媒体库 ──

  /// 返回当前激活库；一个库都没有时自动创建「默认媒体库」。
  ///
  /// 新用户可能先加文件夹/共享源再建库，这里保证数据总有归属。
  ImageLibrary _ensureActiveLibrary() {
    final existing = activeLibrary;
    if (existing != null) return existing;
    final lib = ImageLibrary(
      id: 'lib_default',
      name: _defaultLibraryName(),
      folderPaths: [],
    );
    _libraries.add(lib);
    _activeLibraryId = lib.id;
    return lib;
  }

  /// 设置库列表是否显示隐藏库（关闭时列表中完全不出现）。
  ///
  /// 关闭开关时，若当前激活库是隐藏库，会自动切换到第一个未隐藏的库并返回
  /// true，调用方需要同步 [SlideProvider] 的文件夹。没有未隐藏库时保持原状
  /// 并返回 false（此时库列表里一个库也不显示）。
  bool setShowHiddenLibraries(bool value) {
    if (_showHiddenLibraries == value) return false;
    _showHiddenLibraries = value;

    var activeChanged = false;
    if (!value) {
      final active = activeLibrary;
      if (active != null && active.hidden) {
        for (final lib in _libraries) {
          if (!lib.hidden) {
            _activeLibraryId = lib.id;
            _lastFolderPaths = lib.folderPaths;
            activeChanged = true;
            break;
          }
        }
      }
    }

    notifyListeners();
    _saveSettings();
    return activeChanged;
  }

  /// 新建一个空库并切换到它（名称自动去重，避免两个同名库难以区分）
  void addLibrary(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    var unique = trimmed;
    var suffix = 2;
    while (_libraries.any((lib) => lib.name == unique)) {
      unique = '$trimmed $suffix';
      suffix++;
    }

    final lib = ImageLibrary(
      id: 'lib_${DateTime.now().microsecondsSinceEpoch}',
      name: unique,
      folderPaths: [],
    );
    _libraries.add(lib);
    _activeLibraryId = lib.id;
    _lastFolderPaths = [];
    notifyListeners();
    _saveSettings();
  }

  void renameLibrary(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    for (final lib in _libraries) {
      if (lib.id != id) continue;
      if (lib.name == trimmed) return;
      lib.name = trimmed;
      notifyListeners();
      _saveSettings();
      return;
    }
  }

  /// 删除指定库。不删除文件；只剩一个库时拒绝删除。
  void removeLibrary(String id) {
    if (_libraries.length <= 1) return;
    final before = _libraries.length;
    _libraries.removeWhere((lib) => lib.id == id);
    if (_libraries.length == before) return;
    if (_activeLibraryId == id) {
      _activeLibraryId = _libraries.first.id;
    }
    _lastFolderPaths = activeLibrary?.folderPaths ?? [];
    _pruneUnusedSharedFolders();
    notifyListeners();
    _saveSettings();
  }

  /// 切换激活库。调用方需要自行更新 [SlideProvider] 的文件夹并重扫。
  void switchLibrary(String id) {
    if (_activeLibraryId == id) return;
    if (!_libraries.any((lib) => lib.id == id)) return;
    _activeLibraryId = id;
    _lastFolderPaths = activeLibrary?.folderPaths ?? [];
    notifyListeners();
    _saveSettings();
  }

  /// 设置某个库是否隐藏。
  ///
  /// 若隐藏的正是当前激活库且还有其他未隐藏的库，会自动切换到第一个未隐藏
  /// 的库，避免当前库从列表中消失后无处可寻。此时返回 true，调用方需要同步
  /// [SlideProvider] 的文件夹；全部库都被隐藏时保持当前库不变并返回 false。
  bool setLibraryHidden(String id, bool hidden) {
    ImageLibrary? target;
    for (final lib in _libraries) {
      if (lib.id == id) {
        target = lib;
        break;
      }
    }
    if (target == null || target.hidden == hidden) return false;

    target.hidden = hidden;
    var activeChanged = false;
    if (hidden && _activeLibraryId == id) {
      for (final lib in _libraries) {
        if (!lib.hidden) {
          _activeLibraryId = lib.id;
          _lastFolderPaths = lib.folderPaths;
          activeChanged = true;
          break;
        }
      }
    }
    notifyListeners();
    _saveSettings();
    return activeChanged;
  }

  /// 查找包含指定图片路径的库（按文件夹路径前缀匹配）。
  ///
  /// 双击打开的图片可能位于库文件夹的任意子目录中，因此用前缀而非精确匹配。
  /// 同一文件夹可归属多个库，此时返回先命中的那个。找不到返回 null。
  ///
  /// [includeHidden] 为 false 时跳过隐藏库，保证切换到的是列表中可见的库。
  ImageLibrary? libraryContainingPath(
    String imagePath, {
    bool includeHidden = true,
  }) {
    final image = _normalizePath(imagePath);
    if (image.isEmpty) return null;
    for (final lib in _libraries) {
      if (!includeHidden && lib.hidden) continue;
      for (final folder in lib.folderPaths) {
        final root = _normalizePath(folder);
        if (root.isEmpty) continue;
        if (image == root || image.startsWith('$root/')) return lib;
      }
    }
    return null;
  }

  /// 双击打开图片时自动切换库：
  /// 若图片属于某个库且该库不是当前激活库，则切换并返回 true。
  ///
  /// 隐藏库仅在开启「显示隐藏媒体库」时才参与匹配：开关关闭时它不出现在
  /// 列表中，切过去会与界面状态矛盾。
  bool switchToLibraryForPath(String imagePath) {
    final lib = libraryContainingPath(
      imagePath,
      includeHidden: _showHiddenLibraries,
    );
    if (lib == null || lib.id == _activeLibraryId) return false;
    switchLibrary(lib.id);
    return true;
  }

  /// 归一化路径用于前缀比较：统一分隔符、去掉末尾分隔符，Windows 下忽略大小写
  static String _normalizePath(String path) {
    var normalized = path.trim().replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
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
    // 排除记录归属于图片所在库（远程排除时激活库可能不是该文件所在的库）；
    // 不属于任何库时归入当前激活库
    final target =
        libraryContainingPath(path, includeHidden: true) ?? activeLibrary;
    final list = target?.excludedPaths ?? _excludedPaths;
    if (list.contains(path)) return;
    list.add(path);
    notifyListeners();
    _saveSettings();
  }

  void removeExcludedPath(String path) {
    var changed = false;
    // 恢复播放是全局语义：同一个图片可能在多个库里各自被排除过
    for (final lib in _libraries) {
      final before = lib.excludedPaths.length;
      lib.excludedPaths.removeWhere((item) => item == path);
      if (lib.excludedPaths.length != before) changed = true;
    }
    final before = _excludedPaths.length;
    // 历史数据里可能存在重复路径，这里一次性全部移除
    _excludedPaths.removeWhere((item) => item == path);
    if (_excludedPaths.length != before) changed = true;
    if (!changed) return;
    notifyListeners();
    _saveSettings();
  }

  void clearExcludedPaths() {
    _excludedPaths.clear();
    for (final lib in _libraries) {
      lib.excludedPaths.clear();
    }
    notifyListeners();
    _saveSettings();
  }

  /// 批量移除已排除路径，只触发一次通知与保存
  void removeExcludedPaths(Iterable<String> paths) {
    final targets = paths.toSet();
    if (targets.isEmpty) return;
    var changed = false;
    final before = _excludedPaths.length;
    _excludedPaths.removeWhere(targets.contains);
    if (_excludedPaths.length != before) changed = true;
    for (final lib in _libraries) {
      final size = lib.excludedPaths.length;
      lib.excludedPaths.removeWhere(targets.contains);
      if (lib.excludedPaths.length != size) changed = true;
    }
    if (!changed) return;
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

    // 先读语言，保证迁移时创建的默认库名称使用用户选择的语言
    _languageIndex = prefs.getInt('languageIndex') ?? 0;

    _lastFolderPath = prefs.getString('lastFolderPath');
    final lastFolderPathsStr = prefs.getString('lastFolderPaths');
    if (lastFolderPathsStr != null) {
      _lastFolderPaths = json.decode(lastFolderPathsStr).cast<String>();
    }

    // 多媒体库：优先读取已保存的库列表；老用户只有 lastFolderPaths 时
    // 自动迁移为「默认媒体库」，文件夹、排序与进度都保持不变。
    _libraries = [];
    // 旧版本的库 JSON 没有 sharedFolderKeys 字段，需要把已登记的共享源
    // 归入当前库（读取完 sharedFolders 后再执行，见下方）
    var legacyLibraryFormat = false;
    final librariesStr = prefs.getString('libraries');
    if (librariesStr != null) {
      try {
        final decoded = json.decode(librariesStr);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map && entry['sharedFolderKeys'] is! List) {
              legacyLibraryFormat = true;
            }
            final lib = ImageLibrary.fromJson(entry);
            if (lib != null) _libraries.add(lib);
          }
        }
      } catch (_) {
        // 数据损坏时忽略，走下方迁移逻辑
      }
    }
    _activeLibraryId = prefs.getString('activeLibraryId') ?? '';
    final hasActive = _libraries.any((lib) => lib.id == _activeLibraryId);
    if (_libraries.isEmpty && _lastFolderPaths.isNotEmpty) {
      final defaultLib = ImageLibrary(
        id: 'lib_default',
        name: _defaultLibraryName(),
        folderPaths: List<String>.of(_lastFolderPaths),
      );
      _libraries.add(defaultLib);
      _activeLibraryId = defaultLib.id;
    } else if (_libraries.isNotEmpty && !hasActive) {
      _activeLibraryId = _libraries.first.id;
    }
    _showHiddenLibraries = prefs.getBool('showHiddenLibraries') ?? false;

    _showImageInfo = prefs.getBool('showImageInfo') ?? false;

    final excludedStr = prefs.getString('excludedPaths');
    if (excludedStr != null) {
      // 去掉历史数据中的重复路径，避免已排除统计翻倍
      _excludedPaths = json.decode(excludedStr).cast<String>().toSet().toList();
    }
    // 排除记录跟随媒体库：老用户只有全局列表，升级后归入当前激活库
    if (_libraries.isNotEmpty && _excludedPaths.isNotEmpty) {
      final lib = activeLibrary;
      if (lib != null) {
        for (final path in _excludedPaths) {
          if (!lib.excludedPaths.contains(path)) {
            lib.excludedPaths.add(path);
          }
        }
      }
      _excludedPaths = [];
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
    // 旧版本的库没有共享绑定字段：把已登记的全部共享源归入当前库，
    // 保持升级前的可见范围不变。
    if (_libraries.isEmpty && _sharedFolders.isNotEmpty) {
      final defaultLib = ImageLibrary(
        id: 'lib_default',
        name: _defaultLibraryName(),
        folderPaths: List<String>.of(_lastFolderPaths),
        sharedFolderKeys: [for (final ref in _sharedFolders) ref.key],
      );
      _libraries.add(defaultLib);
      _activeLibraryId = defaultLib.id;
    } else if (legacyLibraryFormat && _sharedFolders.isNotEmpty) {
      final lib = activeLibrary;
      if (lib != null) {
        for (final ref in _sharedFolders) {
          if (!lib.sharedFolderKeys.contains(ref.key)) {
            lib.sharedFolderKeys.add(ref.key);
          }
        }
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

  /// 老数据迁移时创建的默认库名称。
  ///
  /// 通过 [AppLocalizations.fromIndex] 解析语言：索引 0（跟随系统）会按系统
  /// 语言选择文案，其余索引与 [AppLanguage] 枚举一致。
  String _defaultLibraryName() {
    final loc = AppLocalizations.fromIndex(_languageIndex);
    if (loc.isEn) return 'Default Library';
    if (loc.isZhTW) return '預設媒體庫';
    return '默认媒体库';
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

    // 多媒体库
    await prefs.setString(
      'libraries',
      json.encode(_libraries.map((item) => item.toJson()).toList()),
    );
    await prefs.setString('activeLibraryId', _activeLibraryId);
    await prefs.setBool('showHiddenLibraries', _showHiddenLibraries);
  }
}
