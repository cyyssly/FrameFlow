class ImageItem {
  final String name;
  final String path;

  /// 图片宽高比（宽/高），用于瀑布流布局。未知时为 null。
  final double? aspectRatio;

  ImageItem({required this.name, required this.path, this.aspectRatio});
}
