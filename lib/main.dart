import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/splash_screen.dart';
import 'screens/home_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/records_screen.dart';

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
          seedColor: const Color(0xFF4CAF50),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const RootNavigator(),
    );
  }
}

// ── Root: Splash → Home → App Shell ─────────────────────────────────────────

class RootNavigator extends StatefulWidget {
  const RootNavigator({super.key});

  @override
  State<RootNavigator> createState() => _RootNavigatorState();
}

class _RootNavigatorState extends State<RootNavigator> {
  _Screen _screen = _Screen.splash;

  @override
  Widget build(BuildContext context) {
    switch (_screen) {
      case _Screen.splash:
        return SplashScreen(
          onFinished: () => setState(() => _screen = _Screen.home),
        );
      case _Screen.home:
        return HomeScreen(
          onGetStarted: () => setState(() => _screen = _Screen.app),
        );
      case _Screen.app:
        return const AppShell();
    }
  }
}

enum _Screen { splash, home, app }

// ── App shell with bottom navigation ────────────────────────────────────────

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;

  final GlobalKey<RecordsScreenState> _recordsKey =
  GlobalKey<RecordsScreenState>();

  void _switchTab(int index) {
    setState(() => _currentIndex = index);
    if (index == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _recordsKey.currentState?.loadFiles();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const CameraScreen(),
          RecordsScreen(key: _recordsKey),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _switchTab,
        selectedItemColor: const Color(0xFF4CAF50),
        unselectedItemColor: Colors.grey,
        backgroundColor: Colors.white,
        elevation: 8,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_alt_outlined),
            activeIcon: Icon(Icons.camera_alt),
            label: 'Scan',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt_outlined),
            activeIcon: Icon(Icons.list_alt),
            label: 'Records',
          ),
        ],
      ),
    );
  }
}