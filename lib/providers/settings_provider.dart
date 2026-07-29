import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlayOrder { sequential, random, newestFirst, oldestFirst, newPreferred }

enum ImageFitMode { contain, cover, original }

enum BackgroundColor { black, darkGray, white }

enum TransitionAnimation {
  none,
  fade,
  slideLeft,
  slideRight,
  slideUp,
  slideDown,
}

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

class SettingsProvider extends ChangeNotifier {
  // 播放基础设置
  int _interval = 5000;
  PlayOrder _playOrder = PlayOrder.sequential;
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
  bool _keepControlsOnPause = true;

  // 文件与目录相关
  bool _recursiveScan = false;

  String? _lastFolderPath;
  List<String> _lastFolderPaths = [];

  // 信息显示设置
  bool _showImageInfo = true;
  bool _infoAutoHide = true;
  int _infoHideDelay = 3;

  // 快捷键与控制
  bool _wheelSwitchImage = true;

  // 删除行为设置
  DeleteAction _deleteAction = DeleteAction.exclude;
  List<String> _excludedPaths = [];

  // 语言设置（0=跟随系统, 1=简体中文, 2=English, 3=繁體中文）
  int _languageIndex = 0;

  // 自定义轮播间隔（毫秒），默认1800秒 = 1800000ms
  int _customInterval = 1800000;

  // Getters
  int get interval => _interval;
  int get customInterval => _customInterval;
  List<String> get excludedPaths => List.unmodifiable(_excludedPaths);
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

  String? get lastFolderPath => _lastFolderPath;
  List<String> get lastFolderPaths => _lastFolderPaths;

  bool get showImageInfo => _showImageInfo;
  bool get infoAutoHide => _infoAutoHide;
  int get infoHideDelay => _infoHideDelay;
  bool get wheelSwitchImage => _wheelSwitchImage;
  DeleteAction get deleteAction => _deleteAction;
  int get languageIndex => _languageIndex;

  // Setters
  void setInterval(int value) {
    _interval = value;
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

  void setInfoAutoHide(bool value) {
    _infoAutoHide = value;
    notifyListeners();
    _saveSettings();
  }

  void setInfoHideDelay(int value) {
    _infoHideDelay = value;
    notifyListeners();
    _saveSettings();
  }

  void setWheelSwitchImage(bool value) {
    _wheelSwitchImage = value;
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
    _excludedPaths.remove(path);
    notifyListeners();
    _saveSettings();
  }

  void clearExcludedPaths() {
    _excludedPaths.clear();
    notifyListeners();
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
    _interval = prefs.getInt('interval') ?? 5000;
    _playOrder = PlayOrder.values[prefs.getInt('playOrder') ?? 0];
    _loopPlay = prefs.getBool('loopPlay') ?? false;
    _autoPlay = prefs.getBool('autoPlay') ?? true;
    _imageFitMode = ImageFitMode.values[prefs.getInt('imageFitMode') ?? 0];
    _backgroundColor =
        BackgroundColor.values[prefs.getInt('backgroundColor') ?? 0];
    _transitionAnimation =
        TransitionAnimation.values[prefs.getInt('transitionAnimation') ?? 1];
    _animationDuration = prefs.getDouble('animationDuration') ?? 0.5;
    _startFullscreen = prefs.getBool('startFullscreen') ?? true;
    _hideToolbar = prefs.getBool('hideToolbar') ?? true;
    _controlsHideDelay = prefs.getInt('controlsHideDelay') ?? 3;
    _keepControlsOnPause = prefs.getBool('keepControlsOnPause') ?? true;
    _recursiveScan = prefs.getBool('recursiveScan') ?? false;

    _lastFolderPath = prefs.getString('lastFolderPath');
    final lastFolderPathsStr = prefs.getString('lastFolderPaths');
    if (lastFolderPathsStr != null) {
      _lastFolderPaths = json.decode(lastFolderPathsStr).cast<String>();
    }
    _showImageInfo = prefs.getBool('showImageInfo') ?? true;
    _infoAutoHide = prefs.getBool('infoAutoHide') ?? true;
    _infoHideDelay = prefs.getInt('infoHideDelay') ?? 3;

    final excludedStr = prefs.getString('excludedPaths');
    if (excludedStr != null) {
      _excludedPaths = json.decode(excludedStr).cast<String>();
    }

    _wheelSwitchImage = prefs.getBool('wheelSwitchImage') ?? true;
    _deleteAction = DeleteAction.values[prefs.getInt('deleteAction') ?? 0];
    _imageOrientation =
        ImageOrientation.values[prefs.getInt('imageOrientation') ?? 2];
    _languageIndex = prefs.getInt('languageIndex') ?? 0;
    _customInterval = prefs.getInt('customInterval') ?? 1800000;

    notifyListeners();
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

    await prefs.setString('lastFolderPath', _lastFolderPath ?? '');
    await prefs.setString('lastFolderPaths', json.encode(_lastFolderPaths));
    await prefs.setInt('deleteAction', _deleteAction.index);
    await prefs.setBool('showImageInfo', _showImageInfo);
    await prefs.setInt('languageIndex', _languageIndex);
    await prefs.setInt('customInterval', _customInterval);
    await prefs.setBool('infoAutoHide', _infoAutoHide);
    await prefs.setInt('infoHideDelay', _infoHideDelay);
    await prefs.setBool('wheelSwitchImage', _wheelSwitchImage);
    await prefs.setString('excludedPaths', json.encode(_excludedPaths));
    await prefs.setInt('imageOrientation', _imageOrientation.index);
  }
}
