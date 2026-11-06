import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frame_flow/l10n/app_localizations.dart';
import 'package:frame_flow/models/image_item.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/screens/player_screen.dart';

/// 复现：播放中“返回上一张”后图片显示“加载失败”。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<ImageItem> images;
  late List<Object> streamErrors;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // 测试环境没有原生实现：拦截 wakelock_plus 的 pigeon BasicMessageChannel。
    // 注意 pigeon 使用自定义 _PigeonCodec，因此这里用原始字节回复，不解析入参。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final reply = const StandardMessageCodec().encodeMessage(<Object?>[null]);
    for (final name in ['toggle', 'isEnabled']) {
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface'
        '.WakelockPlusApi.$name',
        (message) async => reply,
      );
    }

    tempDir = Directory.systemTemp.createTempSync('ff_repro');
    images = [];
    for (var i = 0; i < 3; i++) {
      final file = File('${tempDir.path}${Platform.pathSeparator}img$i.png');
      file.writeAsBytesSync(img.encodePng(img.Image(width: 400, height: 300)));
      images.add(ImageItem(name: 'img$i.png', path: file.path));
    }

    // 直接在同一个 ImageStream 上挂一个 onError 监听，用于抓取被广播的错误。
    streamErrors = [];
    for (final item in images) {
      final stream = FileImage(
        File(item.path),
      ).resolve(ImageConfiguration.empty);
      stream.addListener(
        ImageStreamListener(
          (info, synchronousCall) => info.dispose(),
          onError: (error, stackTrace) => streamErrors.add(error),
        ),
      );
    }
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 让真实的文件读取/解码有机会完成，然后再渲染一帧。
  Future<void> settleRealAsync(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<SlideProvider> pumpPlayer(
    WidgetTester tester, {
    required int startIndex,
    DeleteAction deleteAction = DeleteAction.exclude,
  }) async {
    final slide = SlideProvider();
    final settings = SettingsProvider();
    // 避免测试环境走 Windows FFI 全屏逻辑
    settings.setStartFullscreen(false);
    settings.setAutoPlay(true);
    settings.setPresetInterval(60000);
    settings.setDeleteAction(deleteAction);
    slide.setImages(images);
    slide.goToImage(startIndex);
    slide.startPlay();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SlideProvider>.value(value: slide),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await settleRealAsync(tester);
    return slide;
  }

  /// 与真实交互一致：走全局键盘监听。
  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settleRealAsync(tester);
  }

  /// 当前图片的缩放倍数（取自包裹图片的 Transform 矩阵）。
  ///
  /// 播放页用「图片路径」作为 Transform 的 key（后台补全播放列表时索引会变），
  /// 因此这里同样按当前图片的路径查找。
  double imageScale(WidgetTester tester, SlideProvider slide) {
    final key = ValueKey(slide.images[slide.currentIndex].path);
    final transform = tester.widget<Transform>(find.byKey(key));
    return transform.transform.storage[0];
  }

  testWidgets('返回上一张（目标是刚看过的、已缓存的图片）', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);
    final l10n = AppLocalizations.of(tester.element(find.byType(PlayerScreen)));
    expect(find.text(l10n.imageLoadFailed), findsNothing, reason: '初始就失败');
    expect(slide.currentIndex, 0);

    // 先向前一张（把 img1 正常显示出来），再退回 img0。
    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    expect(slide.currentIndex, 1);
    await pressKey(tester, LogicalKeyboardKey.arrowLeft);
    expect(slide.currentIndex, 0);

    expect(
      find.text(l10n.imageLoadFailed),
      findsNothing,
      reason: '返回上一张后失败；捕获到的流错误：$streamErrors',
    );
    // 图片流本身不应报出任何错误（回归点：build 期间 setState 会被广播为加载失败）
    expect(streamErrors, isEmpty, reason: '图片流报错：$streamErrors');
  });

  testWidgets('第一张往回翻（跨首尾到最后一张）', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);
    final l10n = AppLocalizations.of(tester.element(find.byType(PlayerScreen)));

    await pressKey(tester, LogicalKeyboardKey.arrowLeft);
    expect(slide.currentIndex, 2);

    expect(
      find.text(l10n.imageLoadFailed),
      findsNothing,
      reason: '跨首尾往回翻后失败；捕获到的流错误：$streamErrors',
    );
  });

  testWidgets('放大后按播放（等同于点击播放按钮）：复位缩放并直接切下一张', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);
    expect(slide.currentIndex, 0);

    // ↑ 放大；放大后自动播放暂停（工具栏显示为播放图标 ▶）
    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(
      find.byIcon(Icons.play_circle),
      findsOneWidget,
      reason: '放大状态下工具栏应显示“暂停状态”的播放图标',
    );

    // 等同于点击工具栏播放按钮：视为“这张已看完”，应立即切下一张
    await pressKey(tester, LogicalKeyboardKey.space);
    expect(slide.currentIndex, 1, reason: '放大时点击播放应直接切到下一张');
    expect(
      find.byIcon(Icons.pause_circle),
      findsOneWidget,
      reason: '切图后应恢复自动播放，工具栏显示暂停图标',
    );
  });

  testWidgets('放大后拖到边缘：拖拽过程中不切图，松开左键才切换', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);

    // ↑ 放大。400x300 的图片放大后横向仍不足一屏（横向可平移量为 0，
    // 即一开始就“顶在边缘”），向左拖出属于“顶住左边缘继续往外推”。
    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(slide.currentIndex, 0);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(slide.currentIndex, 0, reason: '拖拽过程中不应立即切图');

    // 松开左键时才判断：仍顶在边缘 → 切下一张
    await gesture.up();
    await tester.pump();
    expect(slide.currentIndex, 1, reason: '松开左键后应切到下一张');
  });

  testWidgets('删除确认对话框打开时，方向键不应切换图片', (tester) async {
    final slide = await pumpPlayer(
      tester,
      startIndex: 0,
      deleteAction: DeleteAction.delete,
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(PlayerScreen)));

    // Del 弹出「确认删除」对话框（删除行为设为“实际删除”时才有确认）
    await pressKey(tester, LogicalKeyboardKey.delete);
    expect(find.byType(AlertDialog), findsOneWidget, reason: '应弹出删除确认框');

    // 对话框打开期间按左右键：只应在按钮间移动焦点，不能切换图片
    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    await pressKey(tester, LogicalKeyboardKey.arrowLeft);
    expect(slide.currentIndex, 0, reason: '确认框打开时方向键不应切换图片');
    expect(find.byType(AlertDialog), findsOneWidget, reason: '确认框应保持打开');

    // 滚轮同样不能切换图片（对话框遮罩 + 切图入口的双重保证）
    final mouse = TestPointer(7, PointerDeviceKind.mouse);
    mouse.hover(const Offset(400, 300));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    mouse.hover(const Offset(400, 300));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await tester.pump();
    expect(slide.currentIndex, 0, reason: '确认框打开时滚轮不应切换图片');

    // 取消后恢复播放，方向键重新生效
    await tester.tap(find.text(l10n.cancel));
    await settleRealAsync(tester);
    // 对话框退场动画期间仍留在组件树上，等动画结束后再断言
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    expect(slide.currentIndex, 1);
  });

  testWidgets('放大状态下删除当前图片后，下一张应恢复原始大小', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);
    expect(imageScale(tester, slide), 1.0);

    // ↑ 放大
    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(imageScale(tester, slide), greaterThan(1.0), reason: '应已进入放大状态');

    // Del = 排除播放（无需确认），当前图片被移除，列表里的下一张顶到同一个位置
    await pressKey(tester, LogicalKeyboardKey.delete);
    expect(slide.images.length, 2);
    expect(slide.currentIndex, 0);

    expect(imageScale(tester, slide), 1.0, reason: '删除后新图不应继承上一张的放大状态');

    // 跑完删除提示的 2 秒定时器，避免测试结束时仍有待处理的 Timer
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('按住 ↑ / ↓ 时应连续放大 / 缩小', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);

    // 首次按下
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await settleRealAsync(tester);
    final afterFirst = imageScale(tester, slide);
    expect(afterFirst, greaterThan(1.0));

    // 按住不放：系统持续投递重复按键事件
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await settleRealAsync(tester);
    final afterRepeat = imageScale(tester, slide);
    expect(afterRepeat, greaterThan(afterFirst), reason: '按住 ↑ 应继续放大');

    // 向下同样连续缩小
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await settleRealAsync(tester);
    final afterZoomOut = imageScale(tester, slide);
    expect(afterZoomOut, lessThan(afterRepeat), reason: '↓ 应缩小');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await settleRealAsync(tester);
    expect(
      imageScale(tester, slide),
      lessThan(afterZoomOut),
      reason: '按住 ↓ 应继续缩小',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  });
}
