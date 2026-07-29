import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/l10n/app_localizations.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).settingsTitle),
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
          // 语言设置
          _buildSectionTitle(AppLocalizations.of(context).languageLabel),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => _buildRadioSetting(
              context,
              AppLocalizations.of(context).languageLabel,
              [
                (AppLocalizations.of(context).systemLang, 0),
                ('简体中文', 1),
                ('English', 2),
                ('繁體中文', 3),
              ],
              settings.languageIndex,
              (value) => settings.setLanguageIndex(value),
            ),
          ),
          const SizedBox(height: 8),
          // 播放基础设置
          _buildSectionTitle(AppLocalizations.of(context).playOrderMode),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildIntervalSetting(
                  context,
                  '轮播间隔时间',
                  settings.interval,
                  settings.customInterval,
                  (value) => settings.setInterval(value),
                  (value) => settings.setCustomInterval(value),
                ),
                _buildRadioSetting(
                  context,
                  AppLocalizations.of(context).playOrderMode,
                  [
                    (
                      AppLocalizations.of(context).sequential,
                      PlayOrder.sequential,
                    ),
                    (AppLocalizations.of(context).randomPlay, PlayOrder.random),
                    (
                      AppLocalizations.of(context).newestFirst,
                      PlayOrder.newestFirst,
                    ),
                    (
                      AppLocalizations.of(context).oldestFirst,
                      PlayOrder.oldestFirst,
                    ),
                    (
                      AppLocalizations.of(context).newPreferred,
                      PlayOrder.newPreferred,
                    ),
                  ],
                  settings.playOrder,
                  (value) => settings.setPlayOrder(value),
                ),
                _buildSwitchSetting(
                  context,
                  '循环播放',
                  AppLocalizations.of(context).loopPlayDesc,
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
          _buildSectionTitle(AppLocalizations.of(context).imageDisplay),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildRadioSetting(
                  context,
                  AppLocalizations.of(context).fitMode,
                  [
                    (
                      AppLocalizations.of(context).contain,
                      ImageFitMode.contain,
                    ),
                    (AppLocalizations.of(context).cover, ImageFitMode.cover),
                    (
                      AppLocalizations.of(context).original,
                      ImageFitMode.original,
                    ),
                  ],
                  settings.imageFitMode,
                  (value) => settings.setImageFitMode(value),
                ),
                _buildRadioSetting(
                  context,
                  AppLocalizations.of(context).backgroundColorLabel,
                  [
                    (AppLocalizations.of(context).black, BackgroundColor.black),
                    (
                      AppLocalizations.of(context).darkGray,
                      BackgroundColor.darkGray,
                    ),
                    (AppLocalizations.of(context).white, BackgroundColor.white),
                  ],
                  settings.backgroundColor,
                  (value) => settings.setBackgroundColor(value),
                ),
                _buildRadioSetting(
                  context,
                  AppLocalizations.of(context).orientationLabel,
                  [
                    (
                      AppLocalizations.of(context).landscape,
                      ImageOrientation.landscape,
                    ),
                    (
                      AppLocalizations.of(context).portrait,
                      ImageOrientation.portrait,
                    ),
                    (
                      AppLocalizations.of(context).followSystem,
                      ImageOrientation.followSystem,
                    ),
                    (
                      AppLocalizations.of(context).followImage,
                      ImageOrientation.followImage,
                    ),
                  ],
                  settings.imageOrientation,
                  (value) => settings.setImageOrientation(value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 切换动画
          _buildSectionTitle(AppLocalizations.of(context).transitionAnimation),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildRadioSetting(
                  context,
                  AppLocalizations.of(context).transitionAnimation,
                  [
                    (
                      AppLocalizations.of(context).none,
                      TransitionAnimation.none,
                    ),
                    (
                      AppLocalizations.of(context).fade,
                      TransitionAnimation.fade,
                    ),
                    (
                      AppLocalizations.of(context).slideLeft,
                      TransitionAnimation.slideLeft,
                    ),
                    (
                      AppLocalizations.of(context).slideUp,
                      TransitionAnimation.slideUp,
                    ),
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
          _buildSectionTitle(AppLocalizations.of(context).windowFullscreen),
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
          _buildSectionTitle(AppLocalizations.of(context).filesAndDirs),
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
          _buildSectionTitle(AppLocalizations.of(context).infoDisplay),
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
          _buildSectionTitle(AppLocalizations.of(context).controlsLabel),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildRadioSetting(
                  context,
                  AppLocalizations.of(context).wheelSwitch,
                  [('切换图片', true), ('缩放图片', false)],
                  settings.wheelSwitchImage,
                  (value) => settings.setWheelSwitchImage(value),
                ),
                _buildRadioSetting(
                  context,
                  AppLocalizations.of(context).deleteBehavior,
                  [
                    (
                      AppLocalizations.of(context).excludeFromPlay,
                      DeleteAction.exclude,
                    ),
                    (
                      AppLocalizations.of(context).deleteFile,
                      DeleteAction.delete,
                    ),
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
    int customInterval,
    void Function(int) onChanged,
    void Function(int) onCustomChanged,
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
          _CustomIntervalInput(
            currentValue: currentValue,
            customInterval: customInterval,
            intervals: intervals,
            onChanged: onChanged,
            onCustomChanged: onCustomChanged,
            intervalLabel: intervalLabel,
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

/// 自定义时间输入组件（StatefulWidget 以保持 TextEditingController 稳定）
class _CustomIntervalInput extends StatefulWidget {
  final int currentValue;
  final int customInterval;
  final List<int> intervals;
  final void Function(int) onChanged;
  final void Function(int) onCustomChanged;
  final String Function(int) intervalLabel;

  const _CustomIntervalInput({
    required this.currentValue,
    required this.customInterval,
    required this.intervals,
    required this.onChanged,
    required this.onCustomChanged,
    required this.intervalLabel,
  });

  @override
  State<_CustomIntervalInput> createState() => _CustomIntervalInputState();
}

class _CustomIntervalInputState extends State<_CustomIntervalInput> {
  late TextEditingController _controller;

  bool get _isCustom => !widget.intervals.contains(widget.currentValue);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '');
  }

  @override
  void didUpdateWidget(covariant _CustomIntervalInput oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _applyValue(String text) {
    final seconds = int.tryParse(text);
    if (seconds != null && seconds > 1 && seconds < 65535) {
      final ms = seconds * 1000;
      widget.onChanged(ms);
      widget.onCustomChanged(ms);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCustom = _isCustom;
    final customSeconds = widget.customInterval ~/ 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilterChip(
              label: Text(
                '自定义',
                style: TextStyle(
                  fontSize: 13,
                  color: isCustom ? Colors.white : Colors.white70,
                ),
              ),
              selected: isCustom,
              onSelected: (_) {
                if (!isCustom) {
                  // 切到自定义模式：使用保存的自定义秒数
                  _controller.text = '$customSeconds';
                  widget.onChanged(widget.customInterval);
                }
              },
              selectedColor: const Color(0xFFe94560),
              backgroundColor: const Color(0xFF0f3460),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 80,
              height: 38,
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: '$customSeconds',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
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
                onChanged: (value) => _applyValue(value),
                onSubmitted: (value) => _applyValue(value),
              ),
            ),
            const SizedBox(width: 8),
            const Text('秒', style: TextStyle(color: Colors.grey, fontSize: 14)),
          ],
        ),
        if (isCustom &&
            (widget.currentValue ~/ 1000 < 2 ||
                widget.currentValue ~/ 1000 > 65534))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '须为大于1且小于65535的整数',
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
