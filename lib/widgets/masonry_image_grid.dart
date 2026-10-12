import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart'
    show SliverGridLayout, SliverGridGeometry, SliverConstraints;
import 'package:slide_show/models/image_item.dart';

/// 瀑布流网格组件：固定列宽，高度按图片宽高比自适应
class MasonryImageGrid extends StatelessWidget {
  /// 单个卡片的参考显示宽度（逻辑像素），用于换算解码宽度。
  static const double tileReferenceWidth = 400;

  /// 卡片图片的解码宽度（物理像素）。
  /// 预解码与卡片渲染必须使用同一个值，否则 ImageCache 的键不一致，预解码就白做了。
  static int decodeWidthFor(BuildContext context) =>
      (tileReferenceWidth * MediaQuery.of(context).devicePixelRatio).round();

  /// 构造卡片使用的 [ImageProvider]，等价于
  /// `Image.file(File(path), cacheWidth: decodeWidthFor(context)).image`。
  static ImageProvider imageProviderFor(String path, BuildContext context) =>
      ResizeImage(FileImage(File(path)), width: decodeWidthFor(context));

  /// 把一批图片真正解码进 [ImageCache]，滚动到它们时即可直接命中缓存。
  /// 仅读取宽高比不会解码像素，必须调用本方法才能消除滚动卡顿。
  /// [concurrency] 为同时解码的张数，过大反而会互相抢占 IO 与解码线程。
  static Future<void> precacheAll(
    List<String> paths,
    BuildContext context, {
    int concurrency = 4,
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

  final List<ImageItem> items;
  final int? selectedIndex;
  final ValueChanged<int> onTap;
  final void Function(int index) onPrimaryAction;
  final void Function(int index) onDelete;
  final void Function(int index) onMove;
  final void Function(int index) onCopy;

  /// 主操作按钮的图标、颜色、提示文字
  final IconData primaryIcon;
  final Color primaryColor;
  final String primaryTooltip;

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
    required this.onPrimaryAction,
    required this.onDelete,
    required this.onMove,
    required this.onCopy,
    required this.primaryIcon,
    required this.primaryColor,
    required this.primaryTooltip,
    this.hasMore = false,
    this.onLoadMore,
    this.prefetchExtent,
  });

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
          final crossAxisCount = constraints.maxWidth < 800
              ? 2
              : (constraints.maxWidth / 400).floor().clamp(2, 10);
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  gridDelegate: _MasonryGridDelegate(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    aspectRatios: items.map((e) => e.aspectRatio).toList(),
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
                      isSelected: selectedIndex == index,
                      onTap: () => onTap(index),
                      onPrimary: () => onPrimaryAction(index),
                      onDelete: () => onDelete(index),
                      onMove: () => onMove(index),
                      onCopy: () => onCopy(index),
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
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onPrimary;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback onCopy;
  final IconData primaryIcon;
  final Color primaryColor;
  final String primaryTooltip;

  const _MasonryImageCard({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.onPrimary,
    required this.onDelete,
    required this.onMove,
    required this.onCopy,
    required this.primaryIcon,
    required this.primaryColor,
    required this.primaryTooltip,
  });

  @override
  State<_MasonryImageCard> createState() => _MasonryImageCardState();
}

class _MasonryImageCardState extends State<_MasonryImageCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Card(
          elevation: widget.isSelected ? 8 : 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: widget.isSelected
                ? const BorderSide(color: Colors.orange, width: 2)
                : BorderSide.none,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image(
                  // 与预解码共用同一个 Provider（含相同的 cacheWidth），
                  // 卡片滚动到可见区域时可直接命中 ImageCache，无需重新解码
                  image: MasonryImageGrid.imageProviderFor(
                    widget.item.path,
                    context,
                  ),
                  fit: BoxFit.fill,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                ),
                // 悬停 或 选中 时显示覆盖层
                if (_isHovered || widget.isSelected) _buildOverlay(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _iconButton(
                  widget.primaryIcon,
                  widget.primaryColor,
                  widget.primaryTooltip,
                  widget.onPrimary,
                ),
                const SizedBox(width: 8),
                _iconButton(
                  Icons.delete_outline,
                  Colors.redAccent,
                  '删除',
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
                  '移动到',
                  widget.onMove,
                ),
                const SizedBox(width: 8),
                _iconButton(
                  Icons.content_copy,
                  Colors.greenAccent,
                  '复制到',
                  widget.onCopy,
                ),
              ],
            ),
          ],
        ),
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

  const _MasonryGridDelegate({
    required this.crossAxisCount,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
    required this.aspectRatios,
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
      final tileHeight = (ratio == null || ratio <= 0)
          ? tileWidth // 未知宽高比时按正方形显示
          : tileWidth / ratio;
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
