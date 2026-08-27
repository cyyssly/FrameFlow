import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart'
    show SliverGridLayout, SliverGridGeometry, SliverConstraints;
import 'package:slide_show/models/image_item.dart';

/// 瀑布流网格组件：固定列宽，高度按图片宽高比自适应
class MasonryImageGrid extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 滚动接近底部（剩余 < 300px）且还有更多时触发加载
        if (hasMore &&
            onLoadMore != null &&
            notification.metrics.extentAfter < 300) {
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
    // 根据设备像素比计算解码宽度，保证清晰度同时避免解码全尺寸大图
    // 卡片显示宽度约 400px，乘以 DPR 得到物理像素宽度
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final decodeWidth = (400 * dpr).round();
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
                Image.file(
                  File(widget.item.path),
                  fit: BoxFit.fill,
                  width: double.infinity,
                  height: double.infinity,
                  // 按 DPR 动态限制解码宽度，保证清晰度同时避免解码全尺寸大图
                  cacheWidth: decodeWidth,
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
