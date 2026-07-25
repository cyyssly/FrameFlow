import 'package:flutter/foundation.dart';
import 'package:slide_show/models/image_item.dart';

class SlideProvider extends ChangeNotifier {
  List<ImageItem> _images = [];
  List<int> _randomOrder = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  int _interval = 3000;
  List<String> _folderPaths = [];

  List<ImageItem> get images => _images;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _isPlaying;
  int get interval => _interval;
  String get folderPath => _folderPaths.isNotEmpty ? _folderPaths.first : '';
  List<String> get folderPaths => _folderPaths;

  void setImages(List<ImageItem> images) {
    _images = images;
    _currentIndex = 0;
    _randomOrder = List.generate(images.length, (i) => i)..shuffle();
    notifyListeners();
  }

  void addImages(List<ImageItem> images) {
    final initialLength = _images.length;
    for (final image in images) {
      if (!_images.any((img) => img.path == image.path)) {
        _images.add(image);
      }
    }
    _randomOrder = List.generate(_images.length, (i) => i)..shuffle();
    notifyListeners();
  }

  void setFolderPath(String path) {
    _folderPaths = [path];
    notifyListeners();
  }

  void setFolderPaths(List<String> paths) {
    _folderPaths = paths;
    notifyListeners();
  }

  void addFolderPath(String path) {
    if (!_folderPaths.contains(path)) {
      _folderPaths.add(path);
      notifyListeners();
    }
  }

  void removeFolderPath(String path) {
    _folderPaths.remove(path);
    notifyListeners();
  }

  void clearFolderPaths() {
    _folderPaths.clear();
    notifyListeners();
  }

  void nextImage({bool random = false}) {
    if (_images.isEmpty) return;
    if (random) {
      _currentIndex = (_currentIndex + 1) % _images.length;
    } else {
      _currentIndex = (_currentIndex + 1) % _images.length;
    }
    notifyListeners();
  }

  void nextRandomImage() {
    if (_images.isEmpty || _randomOrder.isEmpty) return;

    // 找到当前索引在随机序列中的位置
    final currentPos = _randomOrder.indexOf(_currentIndex);

    // 获取下一个随机索引（循环）
    final nextPos = (currentPos + 1) % _randomOrder.length;
    _currentIndex = _randomOrder[nextPos];

    notifyListeners();
  }

  bool isRandomPlaybackComplete() {
    if (_images.isEmpty || _randomOrder.isEmpty) return false;

    // 找到当前索引在随机序列中的位置
    final currentPos = _randomOrder.indexOf(_currentIndex);

    // 如果当前位置是随机序列的最后一个，说明播放完毕
    return currentPos == _randomOrder.length - 1;
  }

  void prevImage() {
    if (_images.isEmpty) return;
    _currentIndex = (_currentIndex - 1 + _images.length) % _images.length;
    notifyListeners();
  }

  void goToImage(int index) {
    if (index >= 0 && index < _images.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  void removeImage(int index) {
    if (index < 0 || index >= _images.length) return;

    // 移除图片
    _images.removeAt(index);

    // 更新随机序列
    _randomOrder.remove(index);
    // 调整随机序列中大于被删除索引的值
    for (int i = 0; i < _randomOrder.length; i++) {
      if (_randomOrder[i] > index) {
        _randomOrder[i]--;
      }
    }

    // 如果被删除的是最后一张图片，当前索引回退到最后一张
    if (_currentIndex >= _images.length) {
      _currentIndex = _images.isNotEmpty ? _images.length - 1 : 0;
    }
    // 如果被删除的是当前图片之前的图片，当前索引减1
    else if (_currentIndex > index) {
      _currentIndex--;
    }

    notifyListeners();
  }

  void togglePlay() {
    _isPlaying = !_isPlaying;
    notifyListeners();
  }

  void setInterval(int milliseconds) {
    _interval = milliseconds;
    notifyListeners();
  }

  void clearImages() {
    _images = [];
    _currentIndex = 0;
    _isPlaying = false;
    _folderPaths.clear();
    _randomOrder = [];
    notifyListeners();
  }

  void shuffleImages() {
    _randomOrder = List.generate(_images.length, (i) => i)..shuffle();
    notifyListeners();
  }
}
