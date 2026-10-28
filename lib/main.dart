import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:frame_flow/screens/home_screen.dart';
import 'package:frame_flow/screens/help_screen.dart';
import 'package:frame_flow/screens/player_screen.dart';
import 'package:frame_flow/screens/settings_screen.dart';
import 'package:frame_flow/providers/slide_provider.dart';
import 'package:frame_flow/providers/settings_provider.dart';
import 'package:frame_flow/providers/lan_provider.dart';
import 'package:frame_flow/services/desktop_tray_service.dart';
import 'package:frame_flow/services/image_formats.dart';
import 'package:frame_flow/services/single_instance_service.dart';
import 'package:frame_flow/services/windows_context_menu_service.dart';
import 'package:frame_flow/l10n/app_localizations.dart';
import 'dart:async';
import 'dart:io';

/// 全局路由观察者。
///
/// 页面可订阅它，在「重新进入」（从子页面返回）时刷新数据。
/// 例如文件夹列表页需要重新统计已选文件夹与已排除文件的数量。
/// 必须注册到 [MaterialApp.navigatorObservers] 才能收到路由事件。
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 全局导航键：供单实例路径转发在任意页面直接跳转到播放页
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 尽早注册单实例通道，防止第二个实例转发来的路径在启动期间丢失
  SingleInstanceService.instance.initializeChannel();

  // 瀑布流会同时预解码「当前批 + 下一批」（各 30 张）。
  // 按卡片真实尺寸解码后单张约 2~3MB，60 张已接近默认的 100MiB 上限，
  // 一旦被驱逐，滚回去时又要重新解码，表现为来回滚动卡顿。
  // 这里放宽到 256MiB（图片像素本身仍按真实卡片尺寸解码，不会失控）。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;

  final settingsProvider = SettingsProvider();
  await settingsProvider.loadSettings();

  // 右键菜单命令记录的是注册时的 exe 绝对路径，便携版被移动过目录后
  // 旧路径就会失效。启动时：
  // · 开关为开 → 按当前 exe 路径重新注册一次；
  // · 开关为关但注册表项仍存在（例如由其他副本注册过）→ 重新注册，
  //   并把开关自动打开，保证换位置后菜单依然可用。
  if (Platform.isWindows) {
    // 注册表里只能存静态文本，按当前语言写入菜单标题与文件类型说明
    final loc = AppLocalizations.fromIndex(settingsProvider.languageIndex);
    if (settingsProvider.addToContextMenu) {
      unawaited(
        WindowsContextMenuService.instance.install(
          menuText: loc.contextMenuOpenWith,
        ),
      );
    } else if (await WindowsContextMenuService.instance.isInstalled()) {
      await WindowsContextMenuService.instance.install(
        menuText: loc.contextMenuOpenWith,
      );
      settingsProvider.setAddToContextMenu(true);
    }
    // 已注册过“候选默认打开程序”时，保持命令路径与当前 exe 一致
    if (await WindowsContextMenuService.instance.hasDefaultAppRegistration()) {
      unawaited(
        WindowsContextMenuService.instance.installDefaultAppRegistration(
          typeName: loc.imageFileTypeName,
          description: loc.imageBrowserDescription,
        ),
      );
    }
  }

  // 右键菜单「用 FrameFlow 打开」会以图片路径作为命令行参数启动
  final initialImagePath = _findOpenImageArgument(args);

  final slideProvider = SlideProvider();
  if (settingsProvider.lastFolderPaths.isNotEmpty) {
    slideProvider.setFolderPaths(settingsProvider.lastFolderPaths);
  }

  final lanProvider = LanProvider(
    settings: settingsProvider,
    slide: slideProvider,
  );
  await lanProvider.initialize();

  // 桌面端：关闭窗口时按设置收起到系统托盘，而不是直接退出
  await DesktopTrayService(settingsProvider).initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsProvider),
        ChangeNotifierProvider.value(value: slideProvider),
        ChangeNotifierProvider.value(value: lanProvider),
      ],
      child: MyApp(initialImagePath: initialImagePath),
    ),
  );

  // 导航树就绪后绑定单实例服务，并补取启动早期收到的转发路径
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      SingleInstanceService.instance.attach(
        navigatorKey: appNavigatorKey,
        slideProvider: slideProvider,
      ),
    );
  });
}

/// 从命令行参数中找出需要直接打开的图片文件。
///
/// 右键菜单「用 FrameFlow 打开」会把文件路径作为唯一参数传入。
/// 同时过滤调试参数（以 `-` 开头）与不存在的文件，避免误判。
String? _findOpenImageArgument(List<String> args) {
  for (final arg in args) {
    final path = arg.trim();
    if (path.isEmpty || path.startsWith('-')) continue;
    if (!isSupportedImagePath(path)) continue;
    if (!File(path).existsSync()) continue;
    return path;
  }
  return null;
}

class MyApp extends StatelessWidget {
  /// 由右键菜单/命令行传入、启动后直接播放的图片路径
  final String? initialImagePath;

  const MyApp({super.key, this.initialImagePath});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final locale = settings.languageIndex == 0
        ? _resolveSystemLocale()
        : AppLanguage.values[settings.languageIndex].locale;

    return MaterialApp(
      title: 'FrameFlow',
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        Locale('en', 'US'),
      ],
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
        fontFamily: 'NotoSansSC',
      ),
      navigatorKey: appNavigatorKey,
      navigatorObservers: [appRouteObserver],
      initialRoute: '/',
      routes: {
        '/': (context) => HomeScreen(initialImagePath: initialImagePath),
        '/player': (context) => const PlayerScreen(),
        '/settings': (context) => const SettingsScreen(),
        '/help': (context) => const HelpScreen(),
      },
    );
  }

  Locale _resolveSystemLocale() {
    final loc = Platform.localeName;
    if (loc.startsWith('zh')) {
      if (loc.contains('TW') || loc.contains('HK') || loc.contains('MO')) {
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      }
      return const Locale('zh', 'CN');
    }
    return const Locale('en', 'US');
  }
}
