/// 支持的图片格式（全项目唯一来源，扫描、内网共享与右键菜单都引用这里）。
///
/// 与播放能力无关：这几种格式在桌面端与 Android 端都能正常解码显示。
const Set<String> supportedImageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'gif',
};

/// 按扩展名判断路径是否为受支持的图片。
bool isSupportedImagePath(String path) {
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex == -1) return false;
  final ext = path.toLowerCase().substring(dotIndex + 1);
  return supportedImageExtensions.contains(ext);
}
