import 'dart:io';
import 'package:flutter/material.dart';

/// 语言选项索引
enum AppLanguage {
  system(0, '跟随系统', Locale('en', 'US')),
  zhCN(1, '简体中文', Locale('zh', 'CN')),
  en(2, 'English', Locale('en', 'US')),
  zhTW(3, '繁體中文', Locale('zh', 'HK'));

  final int value;
  final String label;
  final Locale locale;
  const AppLanguage(this.value, this.label, this.locale);
}

/// 轻量级国际化支持（简体中文 / English / 繁體中文）
class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  /// 语言代码
  String get languageCode => locale.languageCode;
  String get scriptCode => locale.scriptCode ?? '';

  /// 是否为简体中文
  bool get isZhCN => languageCode == 'zh' && scriptCode != 'Hant';

  /// 是否为繁体中文
  bool get isZhTW => languageCode == 'zh' && scriptCode == 'Hant';

  /// 是否为英文
  bool get isEn => languageCode == 'en';

  /// 根据固定语言索引创建实例
  static AppLocalizations fromIndex(int langIndex) {
    switch (langIndex) {
      case 1:
        return AppLocalizations(const Locale('zh', 'CN'));
      case 2:
        return AppLocalizations(const Locale('en', 'US'));
      case 3:
        return AppLocalizations(const Locale('zh', 'HK'));
      default:
        return AppLocalizations(_systemLocale());
    }
  }

  /// 根据系统语言创建实例
  static AppLocalizations of(BuildContext context) {
    return AppLocalizations(Localizations.localeOf(context));
  }

  static Locale _systemLocale() {
    final loc = Platform.localeName;
    if (loc.startsWith('zh')) {
      if (loc.contains('TW') || loc.contains('HK') || loc.contains('MO')) {
        return const Locale('zh', 'HK');
      }
      return const Locale('zh', 'CN');
    }
    return const Locale('en', 'US');
  }

  // ──────────── 翻译 ────────────

  String get appName => _t('FrameFlow', 'FrameFlow', 'FrameFlow');
  String get appTitle => 'FrameFlow';
  String get homeTitle => 'FrameFlow';

  // 首页
  String get startPlay => _t('开始播放', 'Start', '開始播放');
  String get selectAlbum => _t('选择相册', 'Albums', '選擇相冊');
  String get selectFolder => _t('选择文件夹', 'Folders', '選擇文件夾');
  String get settings => _t('设置', 'Settings', '設置');
  String get sponsor => _t('赞助', 'Donate', '贊助');
  String get scanning => _t('正在扫描图片...', 'Scanning...', '正在掃描圖片...');

  // 相册选择页
  String get selectAlbumTitle => _t('选择相册', 'Albums', '選擇相冊');
  String get selectFolderTitle => _t('选择文件夹', 'Folders', '選擇文件夾');
  String get addAlbum => _t('添加相册', 'Add Album', '添加相冊');
  String get addFolder => _t('添加文件夹', 'Add Folder', '添加文件夾');
  String get clearAll => _t('清空全部', 'Clear All', '清空全部');
  String get pleaseAddAlbum => _t('请添加相册', 'Add Albums', '請添加相冊');
  String get pleaseAddFolder => _t('请添加文件夹', 'Add Folders', '請添加文件夾');
  String get confirm => _t('确定', 'OK', '確定');
  String get cancel => _t('取消', 'Cancel', '取消');

  // 播放页
  String get noImages => _t('没有图片', 'No Images', '沒有圖片');
  String get imageLoadFailed => _t('图片加载失败', 'Load Failed', '圖片加載失敗');
  String get unknownDate => _t('未知日期', 'Unknown Date', '未知日期');
  String get rescanning => _t('正在重新扫描...', 'Rescanning...', '正在重新掃描...');

  // 设置页
  String get settingsTitle => _t('设置', 'Settings', '設置');
  String get languageLabel => _t('语言', 'Language', '語言');
  String get systemLang => _t('跟随系统', 'System', '跟隨系統');
  String get playOrderMode => _t('播放顺序模式', 'Play Order', '播放順序模式');
  String get sequential => _t('顺序播放', 'Sequential', '順序播放');
  String get randomPlay => _t('随机播放', 'Random', '隨機播放');
  String get newestFirst => _t('由新到旧', 'Newest First', '由新到舊');
  String get oldestFirst => _t('由旧到新', 'Oldest First', '由舊到新');
  String get newPreferred => _t('新图优先', 'New Preferred', '新圖優先');
  String get loopPlay => _t('循环播放', 'Loop', '循環播放');
  String get loopPlayDesc =>
      _t('关闭：播完停止；开启：首尾循环', 'Off: stop at end; On: loop', '關閉：播完停止；開啟：首尾循環');
  String get autoPlay => _t('自动播放', 'Auto Play', '自動播放');
  String get interval => _t('轮播间隔', 'Interval', '輪播間隔');
  String get imageDisplay => _t('图片显示', 'Display', '圖片顯示');
  String get fitMode => _t('填充模式', 'Fit Mode', '填充模式');
  String get contain => _t('适应窗口', 'Contain', '適應窗口');
  String get cover => _t('填满窗口', 'Cover', '填滿窗口');
  String get original => _t('原图大小', 'Original', '原圖大小');
  String get backgroundColorLabel => _t('背景底色', 'Background', '背景底色');
  String get black => _t('黑色', 'Black', '黑色');
  String get darkGray => _t('深灰', 'Dark Gray', '深灰');
  String get white => _t('白色', 'White', '白色');
  String get orientationLabel => _t('屏幕方向', 'Orientation', '屏幕方向');
  String get landscape => _t('横屏', 'Landscape', '橫屏');
  String get portrait => _t('竖屏', 'Portrait', '豎屏');
  String get followSystem => _t('跟随系统', 'System', '跟隨係統');
  String get followImage => _t('跟随图片', 'Follow Image', '跟隨圖片');
  String get transitionAnimation => _t('切换动画', 'Transition', '切換動畫');
  String get none => _t('无动画', 'None', '無動畫');
  String get fade => _t('淡入淡出', 'Fade', '淡入淡出');
  String get slideLeft => _t('左右滑动', 'Slide Left', '左右滑動');
  String get slideRight => _t('右左滑动', 'Slide Right', '右左滑動');
  String get slideUp => _t('上下滑动', 'Slide Up', '上下滑動');
  String get slideDown => _t('下上滑动', 'Slide Down', '下上滑動');
  String get animDuration => _t('动画时长', 'Duration', '動畫時長');
  String get windowFullscreen => _t('窗口/全屏', 'Window', '窗口/全屏');
  String get startFullscreen => _t('启动自动全屏', 'Fullscreen', '啟動自動全屏');
  String get startFullscreenDesc =>
      _t('打开幻灯直接进入全屏', 'Enter fullscreen on start', '打開幻燈直接進入全屏');
  String get hideToolbarLabel => _t('自动隐藏工具栏', 'Hide Toolbar', '自動隱藏工具欄');
  String get hideToolbarDesc => _t(
    '一段时间无操作自动隐藏上下工具栏',
    'Auto-hide controls after idle',
    '一段時間無操作自動隱藏上下工具欄',
  );
  String get hideDelay => _t('隐藏延迟', 'Hide Delay', '隱藏延遲');
  String get keepOnPause => _t('暂停时保持工具栏', 'Keep on Pause', '暫停時保持工具欄');
  String get keepOnPauseDesc => _t(
    '暂停播放时不自动隐藏播放工具栏',
    'Keep controls visible when paused',
    '暫停播放時不自動隱藏播放工具欄',
  );
  String get filesAndDirs => _t('文件与目录', 'Files & Folders', '文件與目錄');
  String get recursiveScan => _t('递归扫描子文件夹', 'Recursive', '遞歸掃描子文件夾');
  String get recursiveScanDesc => _t(
    '开启后同时读取子文件夹中的图片文件',
    'Scan images in subfolders too',
    '開啟後同時讀取子文件夾中的圖片文件',
  );
  String get infoDisplay => _t('信息显示', 'Info', '信息顯示');
  String get showImageInfo => _t('图片信息显示', 'Show Info', '圖片信息顯示');
  String get showImageInfoDesc => _t(
    '文件名/文件大小/分辨率/当前页码',
    'Name / Size / Resolution / Page',
    '文件名/文件大小/分辨率/當前頁碼',
  );
  String get infoAutoHideLabel => _t('信息条自动隐藏', 'Auto-hide Info', '信息條自動隱藏');
  String get infoAutoHideDesc =>
      _t('几秒无操作自动消失', 'Hide after idle seconds', '幾秒無操作自動消失');
  String get infoHideDelay => _t('信息隐藏延迟', 'Info Hide Delay', '信息隱藏延遲');
  String get controlsLabel => _t('快捷键与控制', 'Controls', '快捷鍵與控制');
  String get wheelSwitch => _t('滚轮切换图片', 'Scroll Wheel', '滾輪切換圖片');
  String get wheelSwitchImage => _t('切换图片', 'Switch Image', '切換圖片');
  String get wheelZoom => _t('缩放图片', 'Zoom', '縮放圖片');
  String get deleteBehavior => _t('删除行为', 'Delete', '刪除行為');
  String get excludeFromPlay => _t('排除播放', 'Exclude', '排除播放');
  String get deleteFile => _t('实际删除', 'Delete File', '實際刪除');
  String get second => _t('秒', 's', '秒');
  String get deleteFromDisk => _t('从磁盘删除', 'Delete from Disk', '從磁盤刪除');
  String get playbackComplete => _t('播放完毕', 'Playback Complete', '播放完畢');
  String get allImagesPlayed =>
      _t('所有图片已播放完毕', 'All images have been shown', '所有圖片已播放完畢');
  String get confirmExclude => _t('确认排除', 'Confirm Exclude', '確認排除');
  String get confirmDelete => _t('确认删除', 'Confirm Delete', '確認刪除');
  String confirmDeleteMsg(String action) =>
      _t('确定要$action这张图片吗？', 'Delete this image?', '確定要$action這張圖片嗎？');
  String get deleteFailed =>
      _t('文件删除失败，可能被其他程序占用', 'Delete failed: file in use', '文件刪除失敗，可能被其他程序佔用');
  String get excluded => _t('图片已排除播放', 'Image excluded', '圖片已排除播放');
  String get deleted => _t('图片已删除', 'Image deleted', '圖片已刪除');
  String get noFolderSelected => _t('没有选择文件夹', 'No folder selected', '沒有選擇文件夾');
  String get shortcutTitle => _t('内置快捷键', 'Shortcuts', '內置快捷鍵');
  String get playPause => _t('播放/暂停', 'Play / Pause', '播放/暫停');
  String get previous => _t('上一张', 'Previous', '上一張');
  String get next => _t('下一张', 'Next', '下一張');
  String get rescan => _t('重新扫描', 'Rescan', '重新掃描');
  String get exitFullscreen => _t('退出全屏', 'Exit Fullscreen', '退出全屏');
  String get enterFullscreen => _t('全屏', 'Fullscreen', '全屏');
  String get rotate => _t('旋转', 'Rotate', '旋轉');
  String get customLabel => _t('自定义', 'Custom', '自定義');
  String get shortcutHint => _t(
    'ESC: 退出全屏 | 空格: 播放/暂停 | ←→: 切换',
    'ESC: Fullscreen | Space: Play/Pause | ←→: Navigate',
    'ESC: 退出全屏 | 空格: 播放/暫停 | ←→: 切換',
  );
  String get errorRange => _t(
    '须为大于1且小于65535的整数',
    'Enter a number between 2 and 65534',
    '須為大於1且小於65535的整數',
  );
  String get msgSelectFolderFirst =>
      _t('请先设置要播放幻灯的图片目录', 'Select folders first', '請先設置要播放幻燈的圖片目錄');
  String get msgReselectFolder =>
      _t('选定的目录下没有图片，请重新选择', 'No images, please reselect', '選定目錄下沒有圖片，請重新選擇');
  String get msgScanError =>
      _t('扫描图片失败，请重试', 'Scan failed, please retry', '掃描圖片失敗，請重試');
  String get msgAutoScanError => _t('自动扫描失败', 'Auto-scan failed', '自動掃描失敗');
  String get back => _t('返回', 'Back', '返回');

  // 消息
  String msgScanComplete(int c) =>
      _t('扫描完成，共 $c 张图片', 'Done: $c images', '掃描完成，共 $c 張圖片');
  String get msgNoImages => _t('选定的目录下没有图片', 'No images found', '選定目錄下沒有圖片');
  String get msgAddFolderFirst => _t('请先添加文件夹', 'Add folders first', '請先添加文件夾');
  String get msgNeedPermission =>
      _t('需要存储读取权限', 'Permission required', '需要存儲讀取權限');
  String get msgNoAlbumsFound =>
      _t('未找到包含图片的相册', 'No albums found', '未找到包含圖片的相冊');
  String msgScanFailed(String e) => _t('扫描失败: $e', 'Failed: $e', '掃描失敗: $e');

  // 排除图片浏览
  String get excludedFolder => _t('已排除的图片', 'Excluded Images', '已排除的圖片');
  String get noExcludedImages =>
      _t('没有已排除的图片', 'No excluded images', '沒有已排除的圖片');
  String get imageRestored => _t('图片已恢复', 'Image restored', '圖片已恢復');
  String get allImagesRestored =>
      _t('所有图片已恢复', 'All images restored', '所有圖片已恢復');
  String get restoreAll => _t('恢复全部', 'Restore All', '恢復全部');
  String get excludeFolderVirtual => _t('已排除的文件', 'Excluded Files', '已排除的文件');
  String get deleteImage => _t('删除', 'Delete', '刪除');
  String get moveTo => _t('移动到', 'Move To', '移動到');
  String get copyTo => _t('复制到', 'Copy To', '複製到');
  String get restore => _t('恢复', 'Restore', '恢復');
  String get deleteAll => _t('删除全部', 'Delete All', '刪除全部');
  String get moveAllTo => _t('全部移动到', 'Move All To', '全部移動到');
  String get copyAllTo => _t('全部复制到', 'Copy All To', '全部複製到');
  String get deletedAll => _t('全部已删除', 'All deleted', '全部已刪除');
  String get movedAllTo => _t('已全部移动', 'All moved', '已全部移動');
  String get copiedAllTo => _t('已全部复制', 'All copied', '已全部複製');
  String get moveFailed => _t('移动失败', 'Move failed', '移動失敗');
  String get copyFailed => _t('复制失败', 'Copy failed', '複製失敗');
  String get copySuccess => _t('复制成功', 'Copied', '複製成功');

  // 内部翻译方法
  String _t(String zhCN, String en, String zhTW) {
    if (isZhCN) return zhCN;
    if (isZhTW) return zhTW;
    return en;
  }
}
