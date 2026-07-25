import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/providers/settings_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 播放基础设置
          _buildSectionTitle('播放基础设置'),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildIntervalSetting(
                  context,
                  '轮播间隔时间',
                  settings.interval,
                  (value) => settings.setInterval(value),
                ),
                _buildRadioSetting(
                  context,
                  '播放顺序模式',
                  [('顺序播放', PlayOrder.sequential), ('随机播放', PlayOrder.random)],
                  settings.playOrder,
                  (value) => settings.setPlayOrder(value),
                ),
                _buildSwitchSetting(
                  context,
                  '循环播放',
                  '关闭：播放到最后一张停止；开启：首尾循环',
                  settings.loopPlay,
                  (value) => settings.setLoopPlay(value),
                ),
                _buildSwitchSetting(
                  context,
                  '自动播放',
                  '进入应用后立即开始播放幻灯片',
                  settings.autoPlay,
                  (value) => settings.setAutoPlay(value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 图片显示设置
          _buildSectionTitle('图片显示设置'),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildRadioSetting(
                  context,
                  '图片填充模式',
                  [
                    ('适应窗口', ImageFitMode.contain),
                    ('填满窗口', ImageFitMode.cover),
                  ],
                  settings.imageFitMode,
                  (value) => settings.setImageFitMode(value),
                ),
                _buildRadioSetting(
                  context,
                  '背景底色',
                  [
                    ('黑色', BackgroundColor.black),
                    ('深灰', BackgroundColor.darkGray),
                    ('白色', BackgroundColor.white),
                  ],
                  settings.backgroundColor,
                  (value) => settings.setBackgroundColor(value),
                ),
                _buildRadioSetting(
                  context,
                  '图片显示方向',
                  [
                    ('横屏', ImageOrientation.landscape),
                    ('竖屏', ImageOrientation.portrait),
                    ('跟随系统', ImageOrientation.followSystem),
                    ('跟随图片', ImageOrientation.followImage),
                  ],
                  settings.imageOrientation,
                  (value) => settings.setImageOrientation(value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 切换动画
          _buildSectionTitle('切换动画'),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildRadioSetting(
                  context,
                  '切换动画选择',
                  [
                    ('无动画', TransitionAnimation.none),
                    ('淡入淡出', TransitionAnimation.fade),
                    ('左右滑动', TransitionAnimation.slideLeft),
                    ('上下滑动', TransitionAnimation.slideUp),
                  ],
                  settings.transitionAnimation,
                  (value) => settings.setTransitionAnimation(value),
                ),
                _buildSliderSetting(
                  context,
                  '动画时长',
                  '${settings.animationDuration.toStringAsFixed(1)}秒',
                  settings.animationDuration,
                  0.1,
                  1.0,
                  0.1,
                  (value) => settings.setAnimationDuration(value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 窗口/全屏控制
          _buildSectionTitle('窗口/全屏控制'),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildSwitchSetting(
                  context,
                  '启动自动全屏',
                  '打开幻灯直接进入全屏',
                  settings.startFullscreen,
                  (value) => settings.setStartFullscreen(value),
                ),
                _buildSwitchSetting(
                  context,
                  '隐藏工具栏',
                  '一段时间无操作自动隐藏上下工具栏',
                  settings.hideToolbar,
                  (value) => settings.setHideToolbar(value),
                ),
                _buildSliderSetting(
                  context,
                  '控制栏隐藏延迟',
                  '${settings.controlsHideDelay}秒',
                  settings.controlsHideDelay.toDouble(),
                  1,
                  15,
                  1,
                  (value) => settings.setControlsHideDelay(value.toInt()),
                ),
                _buildSwitchSetting(
                  context,
                  '暂停时保持工具栏',
                  '暂停播放时不自动隐藏播放工具栏',
                  settings.keepControlsOnPause,
                  (value) => settings.setKeepControlsOnPause(value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 文件与目录相关
          _buildSectionTitle('文件与目录相关'),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildSwitchSetting(
                  context,
                  '包含子文件夹文件',
                  '开启后同时读取子文件夹中的图片文件',
                  settings.recursiveScan,
                  (value) => settings.setRecursiveScan(value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 信息显示设置
          _buildSectionTitle('信息显示设置'),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildSwitchSetting(
                  context,
                  '显示图片信息',
                  '文件名/文件大小/分辨率/当前页码',
                  settings.showImageInfo,
                  (value) => settings.setShowImageInfo(value),
                ),
                _buildSwitchSetting(
                  context,
                  '信息条自动隐藏',
                  '几秒无操作自动消失',
                  settings.infoAutoHide,
                  (value) => settings.setInfoAutoHide(value),
                ),
                _buildSliderSetting(
                  context,
                  '信息条隐藏延迟',
                  '${settings.infoHideDelay}秒',
                  settings.infoHideDelay.toDouble(),
                  1,
                  15,
                  1,
                  (value) => settings.setInfoHideDelay(value.toInt()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 快捷键与控制
          _buildSectionTitle('快捷键与控制'),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildRadioSetting(
                  context,
                  '鼠标滚轮行为',
                  [('切换图片', true), ('缩放图片', false)],
                  settings.wheelSwitchImage,
                  (value) => settings.setWheelSwitchImage(value),
                ),
                _buildRadioSetting(
                  context,
                  '删除按钮行为',
                  [
                    ('排除播放', DeleteAction.exclude),
                    ('实际删除', DeleteAction.delete),
                  ],
                  settings.deleteAction,
                  (value) => settings.setDeleteAction(value),
                ),
                _buildShortcutInfo(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.blueAccent,
        ),
      ),
    );
  }

  Widget _buildSwitchSetting(
    BuildContext context,
    String title,
    String subtitle,
    bool value,
    void Function(bool) onChanged,
  ) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      value: value,
      onChanged: onChanged,
      activeThumbColor: const Color(0xFFe94560),
    );
  }

  Widget _buildSliderSetting(
    BuildContext context,
    String title,
    String label,
    double value,
    double min,
    double max,
    double division,
    void Function(double) onChanged,
  ) {
    return ListTile(
      title: Text(title),
      subtitle: Slider(
        value: value,
        min: min,
        max: max,
        divisions: ((max - min) / division).round(),
        label: label,
        onChanged: onChanged,
        activeColor: const Color(0xFFe94560),
      ),
      trailing: Text(label, style: const TextStyle(color: Colors.grey)),
    );
  }

  Widget _buildIntervalSetting(
    BuildContext context,
    String title,
    int currentValue,
    void Function(int) onChanged,
  ) {
    // 间隔选项（毫秒）
    const intervals = [
      1000,
      2000,
      3000,
      4000,
      5000,
      6000,
      7000,
      8000,
      9000,
      10000,
      15000,
      20000,
      30000,
      45000,
      60000,
      120000,
      180000,
      300000,
      600000,
    ];
    // 对应的显示文字
    String intervalLabel(int ms) {
      if (ms < 60000) return '${ms ~/ 1000}秒';
      if (ms < 3600000) return '${ms ~/ 60000}分钟';
      return '${ms ~/ 60000}分钟';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 12),
          // 秒级选项
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: intervals.take(10).map((ms) {
              final selected = currentValue == ms;
              return FilterChip(
                label: Text(intervalLabel(ms)),
                selected: selected,
                onSelected: (_) => onChanged(ms),
                selectedColor: const Color(0xFFe94560),
                backgroundColor: const Color(0xFF0f3460),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          // 秒级扩展选项
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: intervals.skip(10).take(5).map((ms) {
              final selected = currentValue == ms;
              return FilterChip(
                label: Text(intervalLabel(ms)),
                selected: selected,
                onSelected: (_) => onChanged(ms),
                selectedColor: const Color(0xFFe94560),
                backgroundColor: const Color(0xFF0f3460),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          // 分钟级选项
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: intervals.skip(15).map((ms) {
              final selected = currentValue == ms;
              return FilterChip(
                label: Text(intervalLabel(ms)),
                selected: selected,
                onSelected: (_) => onChanged(ms),
                selectedColor: const Color(0xFFe94560),
                backgroundColor: const Color(0xFF0f3460),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          // 自定义输入
          Row(
            children: [
              FilterChip(
                label: Text(
                  '自定义',
                  style: TextStyle(
                    fontSize: 13,
                    color: intervals.contains(currentValue)
                        ? Colors.white70
                        : Colors.white,
                  ),
                ),
                selected: !intervals.contains(currentValue),
                onSelected: (_) {},
                selectedColor: const Color(0xFFe94560),
                backgroundColor: const Color(0xFF0f3460),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: TextEditingController(
                    text: !intervals.contains(currentValue)
                        ? '${currentValue ~/ 1000}'
                        : '',
                  ),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '秒数',
                    hintStyle: const TextStyle(
                      color: Colors.grey,
                      fontSize: 14,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade700),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade700),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFe94560)),
                    ),
                    isDense: true,
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  onSubmitted: (value) {
                    final seconds = int.tryParse(value);
                    if (seconds != null && seconds > 1 && seconds < 65535) {
                      onChanged(seconds * 1000);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '秒',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ],
          ),
          if (!intervals.contains(currentValue))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '当前: ${currentValue ~/ 1000}秒（须为大于1且小于65535的整数）',
                style: const TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRadioSetting<T>(
    BuildContext context,
    String title,
    List<(String, T)> options,
    T value,
    void Function(T) onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodyLarge),
          Wrap(
            spacing: 8,
            children: options
                .map(
                  (option) => FilterChip(
                    label: Text(option.$1),
                    selected: value == option.$2,
                    onSelected: (_) => onChanged(option.$2),
                    selectedColor: const Color(0xFFe94560),
                    backgroundColor: const Color(0xFF0f3460),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutInfo(BuildContext context) {
    final shortcuts = [
      ('空格', '播放/暂停'),
      ('←', '上一张'),
      ('→', '下一张'),
      ('R', '重新扫描'),
      ('ESC', '退出全屏'),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0f3460),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.keyboard, size: 20, color: Colors.blueAccent.shade200),
              const SizedBox(width: 8),
              const Text(
                '内置快捷键',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueAccent,
                ),
              ),
            ],
          ),
          const Divider(height: 20, color: Colors.white12),
          ...shortcuts.map(
            (s) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      s.$1,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      s.$2,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
