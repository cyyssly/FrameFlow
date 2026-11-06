import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frame_flow/providers/lan_provider.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/screens/home_screen.dart';
import 'package:frame_flow/screens/player_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String imagePath;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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

    tempDir = Directory.systemTemp.createTempSync('ff_esc');
    for (var i = 0; i < 3; i++) {
      File(
        '${tempDir.path}${Platform.pathSeparator}img$i.png',
      ).writeAsBytesSync(img.encodePng(img.Image(width: 200, height: 150)));
    }
    imagePath = '${tempDir.path}${Platform.pathSeparator}img1.png';
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 构建与 main.dart 一致的路由：'/' 为带初始图片的主界面。
  Future<GlobalKey<NavigatorState>> pumpApp(WidgetTester tester) async {
    final settings = SettingsProvider();
    await settings.loadSettings();
    settings.setStartFullscreen(false);
    final slide = SlideProvider();
    final lan = LanProvider(settings: settings, slide: slide);

    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SlideProvider>.value(value: slide),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<LanProvider>.value(value: lan),
        ],
        child: MaterialApp(
          navigatorKey: navKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          locale: const Locale('zh', 'CN'),
          routes: {
            '/': (context) => HomeScreen(initialImagePath: imagePath),
            '/player': (context) => const PlayerScreen(),
            '/settings': (context) => const Scaffold(),
            '/help': (context) => const Scaffold(),
          },
        ),
      ),
    );

    // 等待文件夹扫描完成并把播放页 push 进路由栈
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(PlayerScreen), findsOneWidget, reason: '应进入播放页');
    return navKey;
  }

  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 32));
    }
  }

  testWidgets('双击打开图片后按 ESC 应回到主菜单', (tester) async {
    final navKey = await pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, rounds: 6);

    expect(navKey.currentState!.canPop(), isFalse);
    expect(find.byType(HomeScreen), findsOneWidget, reason: 'ESC 后应回到主菜单');
  });

  testWidgets('退场动画期间连按 ESC 不应把主菜单也弹掉', (tester) async {
    final navKey = await pumpApp(tester);

    // 第一次 ESC 触发退出，此时播放页仍在树上（退场动画未结束），
    // 第二次 ESC 不应继续出栈把主菜单弹掉，否则导航器为空 → 黑屏。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(navKey.currentState!.canPop(), isFalse);
    expect(find.byType(HomeScreen), findsOneWidget, reason: '连续 ESC 不应把主菜单弹掉');
  });
}
