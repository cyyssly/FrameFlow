import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:slide_show/screens/home_screen.dart';
import 'package:slide_show/screens/player_screen.dart';
import 'package:slide_show/screens/settings_screen.dart';
import 'package:slide_show/providers/slide_provider.dart';
import 'package:slide_show/providers/settings_provider.dart';

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
    return MaterialApp(
      title: '图片幻灯播放器',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/player': (context) => const PlayerScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
    );
  }
}
