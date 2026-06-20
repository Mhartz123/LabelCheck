import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/splash_screen.dart';
import 'screens/home_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/news_screen.dart';
import 'screens/records_screen.dart';
import 'widgets/floating_nav_bar.dart';
import 'theme/app_colors.dart';

List<CameraDescription> globalCameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  globalCameras = await availableCameras();
  runApp(const UIPrototypeApp());
}

class UIPrototypeApp extends StatelessWidget {
  const UIPrototypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VerifyDA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: AppColors.bg,
        useMaterial3: true,
      ),
      home: const RootNavigator(),
    );
  }
}

class RootNavigator extends StatefulWidget {
  const RootNavigator({super.key});

  @override
  State<RootNavigator> createState() => _RootNavigatorState();
}

class _RootNavigatorState extends State<RootNavigator> {
  bool _showSplash = true;
  bool _showHome = true;

  @override
  Widget build(BuildContext context) {
    late Widget child;
    late Key key;

    if (_showSplash) {
      child = SplashScreen(
        onFinished: () => setState(() => _showSplash = false),
      );
      key = const ValueKey('splash');
    } else if (_showHome) {
      child = HomeScreen(
        onGetStarted: () => setState(() => _showHome = false),
      );
      key = const ValueKey('home');
    } else {
      child = const AppShell();
      key = const ValueKey('app');
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (widget, animation) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(animation),
        child: widget,
      ),
      child: KeyedSubtree(key: key, child: child),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // 0 = News, 1 = Scan, 2 = Records
  int _currentIndex = 0;

  final GlobalKey<RecordsScreenState> _recordsKey =
  GlobalKey<RecordsScreenState>();

  void _switchTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);

    if (index == 2) {
      // Reload records every time the Records tab is opened, with a
      // post-frame fallback in case the key isn't attached yet.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _recordsKey.currentState?.loadFiles();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      NewsScreen(
        onScanTap: () => _switchTab(1),
        onRecordsTap: () => _switchTab(2),
      ),
      const CameraScreen(),
      RecordsScreen(key: _recordsKey),
    ];

    return Scaffold(
      // All three tabs stay mounted at all times (so the camera controller
      // and records state are never destroyed/rebuilt) — only their
      // horizontal position is animated to create a sliding cross-fade.
      body: Stack(
        clipBehavior: Clip.hardEdge,
        children: List.generate(screens.length, (i) {
          final isActive = i == _currentIndex;
          return IgnorePointer(
            ignoring: !isActive,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              offset: Offset((i - _currentIndex).toDouble(), 0),
              child: screens[i],
            ),
          );
        }),
      ),
      bottomNavigationBar: FloatingNavBar(
        currentIndex: _currentIndex,
        onTap: _switchTab,
        dark: _currentIndex == 1, // dark bar while camera is active
      ),
    );
  }
}