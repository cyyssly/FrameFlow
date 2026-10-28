import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart'
    show SliverGridLayout, SliverGridGeometry, SliverConstraints;
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/l10n/app_localizations.dart';

/// 瀑布流网格组件：固定列宽，高度按图片宽高比自适应
class MasonryImageGrid extends StatelessWidget {
  /// 宽屏下单个卡片的参考显示宽度（逻辑像素）。
  static const double tileReferenceWidth = 400;

  /// 网格四周内边距（与 [build] 中的 SliverPadding 保持一致）。
  ///
  /// 必须与 [crossAxisSpacing] 相等：两者分别是「屏幕边缘到图片」和
  /// 「图片之间」的间距，取值相同才能让两侧与中间看起来一致。
  static const double gridPadding = 8;

  /// 卡片之间的横向间距（与 [_MasonryGridDelegate] 的参数保持一致）
  static const double crossAxisSpacing = 8;

  /// 卡片之间的纵向间距（与 [_MasonryGridDelegate] 的参数保持一致）
  static const double mainAxisSpacing = 8;

  /// 解码宽度的上浮系数与上下限。
  ///
  /// 略高于真实显示宽度，避免因取整导致轻微发虚；同时设上限，
  /// 防止在超宽屏幕上解码出一张远超所需的巨图。
  static const double _decodeOversample = 1.2;
  static const int _minDecodeWidth = 64;
  static const int _maxDecodeWidth = 2048;

  // ── 卡片下方「文件列表信息」的尺寸 ──
  /// 信息文字的字号
  static const double infoFontSize = 12;

  /// 信息块的上下内边距
  static const double infoVerticalPadding = 6;

  /// 文件名最多显示的行数，超出部分省略号（缩略为一行）
  static const int infoNameMaxLines = 1;

  /// 信息文字样式
  static const TextStyle infoTextStyle = TextStyle(
    fontSize: infoFontSize,
    height: 1.25,
    color: Colors.white70,
  );

  /// 单行信息文字在当前文本缩放下的实际高度。
  ///
  /// 不能用常量硬编码：系统文本缩放（[MediaQuery.textScaler]）会放大行高，
  /// 硬编码会让信息块高度不足、文本底部溢出（出现 overflow 提示条）。
  /// 这里用 [TextPainter] 按渲染时的同一套样式与缩放实测。
  static double infoLineHeightFor(BuildContext context) {
    final painter = TextPainter(
      text: const TextSpan(text: 'X', style: infoTextStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.height;
  }

  /// 按「文件列表信息」模式计算卡片下方信息块的高度。
  ///
  /// 与 [_MasonryGridDelegate] 的额外高度必须取同一个值：
  /// 卡片总高 = 图片高度 + 该值。高度与文件名实际长度无关（按最多行数预留），
  /// 因此每张卡片高度一致、排列整齐。
  static double infoBlockHeightFor(BuildContext context, FileListInfo mode) {
    final lines = switch (mode) {
      FileListInfo.none => 0,
      FileListInfo.name => infoNameMaxLines,
      FileListInfo.nameDateSize => infoNameMaxLines + 1,
    };
    if (lines == 0) return 0;
    return lines * infoLineHeightFor(context) + infoVerticalPadding * 2;
  }

  /// 由可用宽度算出列数（窄屏 2 列，宽屏每 400px 一列）
  static int crossAxisCountFor(double availableWidth) => availableWidth < 800
      ? 2
      : (availableWidth / tileReferenceWidth).floor().clamp(2, 10);

  /// 由可用宽度算出单个卡片的逻辑宽度
  static double tileWidthFor(double availableWidth) {
    final count = crossAxisCountFor(availableWidth);
    return (availableWidth - gridPadding * 2 - crossAxisSpacing * (count - 1)) /
        count;
  }

  /// 卡片图片的解码宽度（物理像素）。
  ///
  /// 按**真实卡片宽度**而非固定的 400 逻辑像素换算：
  /// 手机上 2 列时卡片仅约 180dp，若一律按 400dp × devicePixelRatio
  /// 解码（3.5 倍屏约 1400px），像素量是实际所需的近 60 倍，
  /// 直接拖慢解码与内存占用。
  ///
  /// 预解码与卡片渲染必须使用同一个值，否则 ImageCache 的键不一致，
  /// 预解码就白做了。
  static int decodeWidthFor(BuildContext context) {
    final media = MediaQuery.of(context);
    final tileWidth = tileWidthFor(media.size.width);
    final decodeWidth = (tileWidth * media.devicePixelRatio * _decodeOversample)
        .round();
    return decodeWidth.clamp(_minDecodeWidth, _maxDecodeWidth);
  }

  /// 构造卡片使用的 [ImageProvider]，等价于
  /// `Image.file(File(path), cacheWidth: decodeWidthFor(context)).image`。
  static ImageProvider imageProviderFor(String path, BuildContext context) =>
      ResizeImage(FileImage(File(path)), width: decodeWidthFor(context));

  /// 与 [imageProviderFor] 相同，但支持局域网远端图片（优先使用缩略图）。
  static ImageProvider imageProviderForItem(
    ImageItem item,
    BuildContext context,
  ) {
    if (!item.isRemote) return imageProviderFor(item.path, context);
    final url = item.thumbUrl ?? item.remoteUrl;
    if (url == null || url.isEmpty) return imageProviderFor(item.path, context);
    return ResizeImage(NetworkImage(url), width: decodeWidthFor(context));
  }

  /// 把一批图片真正解码进 [ImageCache]，滚动到它们时即可直接命中缓存。
  /// 仅读取宽高比不会解码像素，必须调用本方法才能消除滚动卡顿。
  /// [concurrency] 为同时解码的张数，过大反而会互相抢占 IO 与解码线程。
  static Future<void> precacheAll(
    List<String> paths,
    BuildContext context, {
    int concurrency = 6,
  }) async {
    for (var i = 0; i < paths.length; i += concurrency) {
      if (!context.mounted) return;
      final chunk = paths.skip(i).take(concurrency);
      await Future.wait(
        chunk.map(
          (path) => precacheImage(
            imageProviderFor(path, context),
            context,
            // 单张失败（损坏/已被删除）不影响其余图片
            onError: (_, _) {},
          ),
        ),
      );
    }
  }

  /// 预解码一批图片项（同时支持本地与远端）
  static Future<void> precacheItems(
    List<ImageItem> items,
    BuildContext context, {
    int concurrency = 6,
  }) async {
    for (var i = 0; i < items.length; i += concurrency) {
      if (!context.mounted) return;
      final chunk = items.skip(i).take(concurrency);
      await Future.wait(
        chunk.map(
          (item) => precacheImage(
            imageProviderForItem(item, context),
            context,
            onError: (_, _) {},
          ),
        ),
      );
    }
  }

  /// 是否显示悬停/选中时的操作按钮覆盖层。
  /// 远端浏览为只读，可直接关闭覆盖层。
  final bool showOverlay;

  final List<ImageItem> items;
  final int? selectedIndex;
  final ValueChanged<int> onTap;

  /// 卡片下方展示的文件信息模式（[FileListInfo.none] 表示不展示信息块）。
  final FileListInfo fileListInfo;

  /// 浏览格式：瀑布流按图片比例铺满，固定画幅裁切填满
  final BrowseLayout layout;

  /// 长按回调（可选）。文件夹图片页用它直接进入幻灯播放。
  final void Function(int index)? onLongPress;

  /// 「删除类」操作的回调。
  ///
  /// 四按钮模式下它是「删除」按钮；单按钮模式下它就是那个唯一的按钮，
  /// 实际行为（排除播放 / 实际删除）由调用方按当前设置决定。
  final void Function(int index) onDelete;

  /// 覆盖层是否只显示右下角的单个按钮（文件夹图片页使用）
  final bool singleActionOverlay;

  /// 单按钮模式下按钮的图标、颜色与提示文字
  final IconData singleActionIcon;
  final Color singleActionColor;
  final String? singleActionTooltip;

  /// 单按钮模式下额外追加在右侧的操作（如远程复制），为空时不显示
  final void Function(int index)? onExtraAction;
  final IconData? extraActionIcon;
  final Color? extraActionColor;
  final String? extraActionTooltip;

  // ── 以下为四按钮模式（已排除图片页）所需的参数 ──
  final void Function(int index)? onPrimaryAction;
  final void Function(int index)? onMove;
  final void Function(int index)? onCopy;
  final IconData? primaryIcon;
  final Color? primaryColor;
  final String? primaryTooltip;

  /// 是否还有更多数据可加载（滚动到底部时触发 [onLoadMore]）
  final bool hasMore;

  /// 滚动接近底部时触发，用于动态加载更多
  final VoidCallback? onLoadMore;

  /// 距底部多少逻辑像素时触发 [onLoadMore]。默认 1.5 倍视口高度，
  /// 留足解码时间，避免"滚到底才开始解码"造成的卡顿。
  final double? prefetchExtent;

  const MasonryImageGrid({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onTap,
    this.fileListInfo = FileListInfo.none,
    this.layout = BrowseLayout.masonry,
    this.onLongPress,
    required this.onDelete,
    this.showOverlay = true,
    this.singleActionOverlay = false,
    this.singleActionIcon = Icons.delete_outline,
    this.singleActionColor = Colors.redAccent,
    this.singleActionTooltip,
    this.onExtraAction,
    this.extraActionIcon,
    this.extraActionColor,
    this.extraActionTooltip,
    this.onPrimaryAction,
    this.onMove,
    this.onCopy,
    this.primaryIcon,
    this.primaryColor,
    this.primaryTooltip,
    this.hasMore = false,
    this.onLoadMore,
    this.prefetchExtent,
  }) : assert(
         singleActionOverlay ||
             (onPrimaryAction != null &&
                 onMove != null &&
                 onCopy != null &&
                 primaryIcon != null &&
                 primaryColor != null &&
                 primaryTooltip != null),
         '四按钮模式必须提供主操作/移动到/复制到回调及其图标、颜色、提示文字',
       );

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 滚动接近底部且还有更多时触发加载。
        // 默认预留 1.5 倍视口高度，让下一批有充足的时间读取宽高比并预解码。
        final metrics = notification.metrics;
        final threshold = prefetchExtent ?? metrics.viewportDimension * 1.5;
        if (hasMore && onLoadMore != null && metrics.extentAfter < threshold) {
          onLoadMore!();
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄屏（<800px）固定2列，否则每400px一列
          final crossAxisCount = crossAxisCountFor(constraints.maxWidth);
          // 固定画幅时所有卡片共用同一宽高比；瀑布流则沿用图片自身比例
          final fixedRatio = layout.aspectRatio;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(gridPadding),
                sliver: SliverGrid(
                  gridDelegate: _MasonryGridDelegate(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: crossAxisSpacing,
                    mainAxisSpacing: mainAxisSpacing,
                    aspectRatios: fixedRatio == null
                        ? items.map((e) => e.aspectRatio).toList()
                        : List<double?>.filled(items.length, fixedRatio),
                    // 卡片信息块高度：所有卡片一致，直接叠加到图片高度上
                    extraHeight: infoBlockHeightFor(context, fileListInfo),
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    // 兜底：内容不足一屏时不会有滚动通知，
                    // 构建到末尾附近的两行时主动触发加载更多
                    if (hasMore &&
                        onLoadMore != null &&
                        index >= items.length - crossAxisCount * 2) {
                      final loadMore = onLoadMore!;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted) loadMore();
                      });
                    }
                    return _MasonryImageCard(
                      item: items[index],
                      fileListInfo: fileListInfo,
                      thumbnailFit: fixedRatio == null
                          ? BoxFit.fill
                          : BoxFit.cover,
                      isSelected: selectedIndex == index,
                      onTap: () => onTap(index),
                      onLongPress: onLongPress == null
                          ? null
                          : () => onLongPress!(index),
                      onDelete: () => onDelete(index),
                      showOverlay: showOverlay,
                      singleActionOverlay: singleActionOverlay,
                      singleActionIcon: singleActionIcon,
                      singleActionColor: singleActionColor,
                      singleActionTooltip: singleActionTooltip,
                      onExtra: onExtraAction == null
                          ? null
                          : () => onExtraAction!(index),
                      extraIcon: extraActionIcon,
                      extraColor: extraActionColor,
                      extraTooltip: extraActionTooltip,
                      onPrimary: onPrimaryAction == null
                          ? null
                          : () => onPrimaryAction!(index),
                      onMove: onMove == null ? null : () => onMove!(index),
                      onCopy: onCopy == null ? null : () => onCopy!(index),
                      primaryIcon: primaryIcon,
                      primaryColor: primaryColor,
                      primaryTooltip: primaryTooltip,
                    );
                  }, childCount: items.length),
                ),
              ),
              // 底部加载指示器
              if (hasMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ── 单个图片卡片（PC悬停 / 移动端点击选中 显示覆盖层） ──
class _MasonryImageCard extends StatefulWidget {
  final ImageItem item;

  /// 卡片下方展示的文件信息模式（[FileListInfo.none] 表示不展示信息块）。
  final FileListInfo fileListInfo;

  /// 缩略图填充方式：瀑布流按图片比例铺满，固定画幅裁切填满
  final BoxFit thumbnailFit;

  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDelete;

  /// 是否显示操作按钮覆盖层
  final bool showOverlay;

  /// 覆盖层是否只显示右下角的单个按钮
  final bool singleActionOverlay;
  final IconData singleActionIcon;
  final Color singleActionColor;
  final String? singleActionTooltip;

  /// 单按钮模式下并排追加的第二个操作（可为空）
  final VoidCallback? onExtra;
  final IconData? extraIcon;
  final Color? extraColor;
  final String? extraTooltip;

  // ── 四按钮模式（已排除图片页）所需的回调与样式 ──
  final VoidCallback? onPrimary;
  final VoidCallback? onMove;
  final VoidCallback? onCopy;
  final IconData? primaryIcon;
  final Color? primaryColor;
  final String? primaryTooltip;

  const _MasonryImageCard({
    required this.item,
    required this.fileListInfo,
    this.thumbnailFit = BoxFit.fill,
    required this.isSelected,
    required this.onTap,
    this.onLongPress,
    required this.onDelete,
    required this.showOverlay,
    required this.singleActionOverlay,
    required this.singleActionIcon,
    required this.singleActionColor,
    this.singleActionTooltip,
    this.onExtra,
    this.extraIcon,
    this.extraColor,
    this.extraTooltip,
    this.onPrimary,
    this.onMove,
    this.onCopy,
    this.primaryIcon,
    this.primaryColor,
    this.primaryTooltip,
  });

  @override
  State<_MasonryImageCard> createState() => _MasonryImageCardState();
}

class _MasonryImageCardState extends State<_MasonryImageCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    // 悬停（桌面端）或选中（移动端点按）都只做「边框变色 + 显示操作图标」提示，
    // 不再给图片加暗色遮罩，避免遮挡图片本身
    final highlighted = _isHovered || widget.isSelected;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Card(
          // 必须归零：Card 默认 margin 为 4，会叠加在网格间距之上，
          // 使实际间距变成「两侧 20 / 中间 16」——既偏宽又不一致。
          // 间距完全交给 SliverPadding 与 GridDelegate 控制。
          margin: EdgeInsets.zero,
          elevation: widget.isSelected ? 8 : 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: highlighted
                ? const BorderSide(color: Colors.orange, width: 2)
                : BorderSide.none,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              children: [
                // 图片区域：占据「卡片总高 - 信息块」的剩余空间
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image(
                        // 与预解码共用同一个 Provider（含相同的 cacheWidth），
                        // 卡片滚动到可见区域时可直接命中 ImageCache，无需重新解码
                        image: MasonryImageGrid.imageProviderForItem(
                          widget.item,
                          context,
                        ),
                        fit: widget.thumbnailFit,
                        width: double.infinity,
                        height: double.infinity,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image),
                      ),
                      // 悬停 或 选中 时显示覆盖层（只有图标按钮，无暗色遮罩）
                      if (highlighted && widget.showOverlay)
                        _buildOverlay(context),
                    ],
                  ),
                ),
                if (widget.fileListInfo != FileListInfo.none)
                  _buildInfoBlock(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 卡片下方的文件信息块。
  ///
  /// 高度取自 [MasonryImageGrid.infoBlockHeightFor]（与布局委托用同一个值）。
  /// 文件名超出宽度时只缩略主体、完整保留后缀；「文件名+日期+大小」模式的
  /// 第二行为「日期，大小」，与文件名一样居中显示；缺失值显示「未知」。
  Widget _buildInfoBlock(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final item = widget.item;
    return SizedBox(
      height: MasonryImageGrid.infoBlockHeightFor(context, widget.fileListInfo),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: MasonryImageGrid.infoVerticalPadding,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _fitDisplayName(context, constraints.maxWidth),
                maxLines: MasonryImageGrid.infoNameMaxLines,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: MasonryImageGrid.infoTextStyle,
              ),
              if (widget.fileListInfo == FileListInfo.nameDateSize)
                Text(
                  // 日期与大小同处一行，用全角逗号分隔
                  '${_formatDate(item.modifiedAt, loc.unknown)}'
                  '，${_formatSize(item.size, loc.unknown)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: MasonryImageGrid.infoTextStyle,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 按可用宽度裁切过长文件名：只缩略主体、完整保留后缀名。
  ///
  /// 例如 `a_very_long_name.jpg` → `a_very_l….jpg`（省略号插在主体与后缀之间），
  /// 后缀始终完整可见。宽度足够时原样返回；连「… + 后缀」都放不下时，
  /// 返回「… + 后缀」由 [Text] 的 ellipsis 兜底再截。
  String _fitDisplayName(BuildContext context, double maxWidth) {
    final name = widget.item.name;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);

    // 必须用「渲染时的最终样式」测宽：Text 会把给定样式合并到 DefaultTextStyle
    // 之上，主题里的 letterSpacing / fontFamily 等会被继承。若只用 infoTextStyle
    // 测量，测得的宽度会偏窄，实际渲染更宽，Text 的 ellipsis 就会把结尾的
    // 后缀一起吃掉。
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(MasonryImageGrid.infoTextStyle);

    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
        maxLines: 1,
      )..layout();
      return painter.width;
    }

    if (maxWidth <= 0 || widthOf(name) <= maxWidth) return name;

    // 拆分主体与后缀；无后缀（或隐藏文件）时后缀为空
    final dot = name.lastIndexOf('.');
    final hasExt = dot > 0 && dot < name.length - 1;
    final stem = hasExt ? name.substring(0, dot) : name;
    final ext = hasExt ? name.substring(dot) : '';

    // 二分找「最长且仍放得下」的主体前缀
    var lo = 0;
    var hi = stem.length;
    var best = '';
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final candidate = '${stem.substring(0, mid)}…$ext';
      if (widthOf(candidate) <= maxWidth) {
        best = candidate;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best.isEmpty ? '…$ext' : best;
  }

  /// 文件修改日期，形如 `2021-06-28`；未知时返回 [unknownText]。
  static String _formatDate(DateTime? time, String unknownText) {
    if (time == null) return unknownText;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  /// 文件大小，形如 `2.4 MB`（B / KB / MB / GB）；未知时返回 [unknownText]。
  static String _formatSize(int? bytes, String unknownText) {
    if (bytes == null) return unknownText;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildOverlay(BuildContext context) {
    final loc = AppLocalizations.of(context);

    // 单按钮模式：仅右下角一个「删除类」按钮（文件夹图片页使用），
    // 实际行为（排除播放 / 实际删除）由调用方按当前设置决定。
    if (widget.singleActionOverlay) {
      return Container(
        alignment: Alignment.bottomRight,
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _iconButton(
              widget.singleActionIcon,
              widget.singleActionColor,
              widget.singleActionTooltip ?? loc.deleteImage,
              widget.onDelete,
            ),
            if (widget.onExtra != null) ...[
              const SizedBox(width: 8),
              _iconButton(
                widget.extraIcon ?? Icons.content_copy,
                widget.extraColor ?? Colors.white,
                widget.extraTooltip ?? loc.copyTo,
                widget.onExtra!,
              ),
            ],
          ],
        ),
      );
    }

    // 四按钮模式：居中 2×2 布局（已排除图片页使用）
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _iconButton(
                widget.primaryIcon!,
                widget.primaryColor!,
                widget.primaryTooltip!,
                widget.onPrimary!,
              ),
              const SizedBox(width: 8),
              _iconButton(
                Icons.delete_outline,
                Colors.redAccent,
                loc.deleteImage,
                widget.onDelete,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _iconButton(
                Icons.drive_file_move_outline,
                Colors.lightBlue,
                loc.moveTo,
                widget.onMove!,
              ),
              const SizedBox(width: 8),
              _iconButton(
                Icons.content_copy,
                Colors.white,
                loc.copyTo,
                widget.onCopy!,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iconButton(
    IconData icon,
    Color color,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Material(
          color: Colors.black.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onPressed,
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}

// ── 瀑布流布局委托：固定列宽，高度按图片宽高比自适应 ──
class _MasonryGridDelegate extends SliverGridDelegate {
  final int crossAxisCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final List<double?> aspectRatios;

  /// 图片区域之外的额外高度（卡片下方信息块）。
  final double extraHeight;

  const _MasonryGridDelegate({
    required this.crossAxisCount,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
    required this.aspectRatios,
    this.extraHeight = 0,
  });

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final usableWidth =
        constraints.crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1);
    final tileWidth = usableWidth / crossAxisCount;

    // 记录每列当前累计高度，把下一项放到最短的列
    final columnHeights = List<double>.filled(crossAxisCount, 0);
    final tileHeights = List<double>.filled(aspectRatios.length, 0);
    final columnOfIndex = List<int>.filled(aspectRatios.length, 0);
    final offsetInColumn = List<double>.filled(aspectRatios.length, 0);

    for (var i = 0; i < aspectRatios.length; i++) {
      final ratio = aspectRatios[i];
      final imageHeight = (ratio == null || ratio <= 0)
          ? tileWidth // 未知宽高比时按正方形显示
          : tileWidth / ratio;
      // 图片区域之下还要留出信息块的高度，卡片总高基于它计算
      final tileHeight = imageHeight + extraHeight;
      // 找到当前最短的列
      var shortest = 0;
      for (var c = 1; c < crossAxisCount; c++) {
        if (columnHeights[c] < columnHeights[shortest]) shortest = c;
      }
      tileHeights[i] = tileHeight;
      columnOfIndex[i] = shortest;
      offsetInColumn[i] = columnHeights[shortest];
      columnHeights[shortest] += tileHeight + mainAxisSpacing;
    }

    return _MasonryGridLayout(
      crossAxisCount: crossAxisCount,
      tileWidth: tileWidth,
      crossAxisSpacing: crossAxisSpacing,
      tileHeights: tileHeights,
      columnOfIndex: columnOfIndex,
      offsetInColumn: offsetInColumn,
    );
  }

  @override
  bool shouldRelayout(_MasonryGridDelegate oldDelegate) {
    return oldDelegate.crossAxisCount != crossAxisCount ||
        oldDelegate.crossAxisSpacing != crossAxisSpacing ||
        oldDelegate.mainAxisSpacing != mainAxisSpacing ||
        oldDelegate.extraHeight != extraHeight ||
        !listEquals(oldDelegate.aspectRatios, aspectRatios);
  }
}

class _MasonryGridLayout extends SliverGridLayout {
  final int crossAxisCount;
  final double tileWidth;
  final double crossAxisSpacing;
  final List<double> tileHeights;
  final List<int> columnOfIndex;
  final List<double> offsetInColumn;

  const _MasonryGridLayout({
    required this.crossAxisCount,
    required this.tileWidth,
    required this.crossAxisSpacing,
    required this.tileHeights,
    required this.columnOfIndex,
    required this.offsetInColumn,
  });

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    // 找到第一个 scrollOffset 大于等于给定偏移的项
    for (var i = 0; i < offsetInColumn.length; i++) {
      if (offsetInColumn[i] + tileHeights[i] >= scrollOffset) return i;
    }
    return 0;
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    // 找到最后一个 scrollOffset 小于等于给定偏移的项
    for (var i = offsetInColumn.length - 1; i >= 0; i--) {
      if (offsetInColumn[i] <= scrollOffset) return i;
    }
    return 0;
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    return SliverGridGeometry(
      scrollOffset: offsetInColumn[index],
      crossAxisOffset: columnOfIndex[index] * (tileWidth + crossAxisSpacing),
      mainAxisExtent: tileHeights[index],
      crossAxisExtent: tileWidth,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount == 0) return 0.0;
    var maxEnd = 0.0;
    for (var i = 0; i < childCount; i++) {
      final end = offsetInColumn[i] + tileHeights[i];
      if (end > maxEnd) maxEnd = end;
    }
    return maxEnd;
  }
}
