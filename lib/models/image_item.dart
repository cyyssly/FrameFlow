/// 图片来源：本地文件或局域网内的远端主机
enum ImageSource { local, remote }

class ImageItem {
  final String name;

  /// 本地图片的绝对路径；远端图片为空字符串。
  final String path;

  /// 图片宽高比（宽/高），用于瀑布流布局。未知时为 null。
  final double? aspectRatio;

  /// 图片来源，默认本地文件
  final ImageSource source;

  /// 远端原图地址（仅 remote 使用）
  final String? remoteUrl;

  /// 远端缩略图地址（仅 remote 使用）
  final String? thumbUrl;

  /// 远端主机 id（仅 remote 使用）
  final String? deviceId;

  /// 远端图片在该主机内的唯一标识（仅 remote 使用）
  final String? remoteId;

  /// 文件修改时间。远端图片由其提供，本地图片通常为 null（回退到 File.stat）。
  final DateTime? modifiedAt;

  /// 文件大小（字节）。远端图片由其提供。
  final int? size;

  ImageItem({
    required this.name,
    required this.path,
    this.aspectRatio,
    this.source = ImageSource.local,
    this.remoteUrl,
    this.thumbUrl,
    this.deviceId,
    this.remoteId,
    this.modifiedAt,
    this.size,
  });

  bool get isRemote => source == ImageSource.remote;

  /// 在列表中去重 / 比较时使用的唯一键。
  ///
  /// 远端图片的 [path] 为空，不能直接用它做去重。
  String get key =>
      isRemote ? 'remote://${deviceId ?? ''}/${remoteId ?? ''}' : path;
}
