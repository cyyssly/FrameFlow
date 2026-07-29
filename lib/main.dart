import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/screens/home_screen.dart';
import 'package:slide_show/screens/player_screen.dart';
import 'package:slide_show/screens/settings_screen.dart';
import 'package:slide_show/providers/slide_provider.dart';
import 'package:slide_show/providers/settings_provider.dart';
import 'package:slide_show/l10n/app_localizations.dart';
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settingsProvider = SettingsProvider();
  await settingsProvider.loadSettings();

  final slideProvider = SlideProvider();
  if (settingsProvider.lastFolderPaths.isNotEmpty) {
    slideProvider.setFolderPaths(settingsProvider.lastFolderPaths);
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsProvider),
        ChangeNotifierProvider.value(value: slideProvider),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final locale = settings.languageIndex == 0
        ? _resolveSystemLocale()
        : AppLanguage.values[settings.languageIndex].locale;

    return MaterialApp(
      title: 'FrameFlow',
      locale: locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('zh', 'HK'),
        Locale('en', 'US'),
      ],
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
        fontFamily: 'NotoSansSC',
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/player': (context) => const PlayerScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
    );
  }

  Locale _resolveSystemLocale() {
    final loc = Platform.localeName;
    if (loc.startsWith('zh')) {
      if (loc.contains('TW') || loc.contains('HK') || loc.contains('MO')) {
        return const Locale('zh', 'HK');
      }
      return const Locale('zh', 'CN');
    }
    return const Locale('en', 'US');
  }
}
