/// 局域网共享播放的协议常量与路径
class LanProtocol {
  /// 协议版本，收发双方不一致时忽略
  static const int version = 1;

  /// 默认 HTTP 数据端口（被占用时服务端会顺延）
  static const int defaultHttpPort = 45888;

  /// UDP 发现端口
  static const int discoveryPort = 45889;

  /// 设备发现广播间隔
  static const Duration beaconInterval = Duration(seconds: 3);

  /// 超过该时间没有心跳即视为离线
  static const Duration deviceTimeout = Duration(seconds: 12);

  static const String infoPath = '/api/v1/info';
  static const String foldersPath = '/api/v1/folders';
  static const String imagesPath = '/api/v1/images';
  static const String imagePath = '/api/v1/image';
  static const String thumbPath = '/api/v1/thumb';

  static const String beaconType = 'beacon';
  static const String probeType = 'probe';
}
