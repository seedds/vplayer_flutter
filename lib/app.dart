import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'providers/app_providers.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/upload_screen.dart';
import 'services/upload_server.dart';
import 'theme.dart';

/// Pure threshold rule: shortest logical side >= 600dp is a tablet
/// (iPad and Android tablets alike).
bool isTabletDimensions(Size logicalSize) => logicalSize.shortestSide >= 600;

/// Tablet detection from the physical display (not the window), so the
/// result is stable regardless of current orientation lock or windowing.
/// Tablets get landscape outside the player; phones stay portrait.
bool get isTabletLayout {
  final displays = WidgetsBinding.instance.platformDispatcher.displays;
  if (displays.isEmpty) return false;
  final display = displays.first;
  return isTabletDimensions(display.size / display.devicePixelRatio);
}

List<DeviceOrientation> appOrientations(bool isTablet) => isTablet
    ? const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]
    : const [DeviceOrientation.portraitUp];

class VPlayerApp extends StatelessWidget {
  const VPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'VPlayer',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const RootShell(),
    );
  }
}

class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell>
    with WidgetsBindingObserver {
  int _tabIndex = 0;
  bool _bootstrapped = false;
  bool _wakelockActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(uploadServerProvider).stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;

    await SystemChrome.setPreferredOrientations(appOrientations(isTabletLayout));

    await ref.read(uploadSettingsProvider.notifier).load();
    await ref.read(videoLibraryProvider).ensureAppDirectories();
    await ref.read(libraryProvider.notifier).refresh();
    await ref.read(serverProvider.notifier).refreshNetwork();
    await ref.read(serverProvider.notifier).startServer(defaultServerPort);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(libraryProvider.notifier).refresh();
      ref.read(serverProvider.notifier).refreshNetwork();
    }
  }

  void _syncWakelock(bool uploadsActive) {
    if (uploadsActive == _wakelockActive) return;
    _wakelockActive = uploadsActive;
    if (uploadsActive) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  void _onTabSelected(int index) {
    setState(() => _tabIndex = index);
    final library = ref.read(libraryProvider);
    switch (index) {
      case 0:
        if (!library.loading) {
          ref.read(libraryProvider.notifier).refresh();
        }
      case 1:
        ref.read(selectionProvider.notifier).cancel();
        ref.read(serverProvider.notifier).refreshNetwork();
      case 2:
        ref.read(selectionProvider.notifier).cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final uploadsActive = ref.watch(
        serverProvider.select((s) => s.activity.activeUploads.isNotEmpty));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _syncWakelock(uploadsActive));

    return CupertinoPageScaffold(
      child: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _tabIndex,
                children: const [
                  LibraryScreen(),
                  UploadScreen(),
                  SettingsScreen(),
                ],
              ),
            ),
          ),
          CupertinoTabBar(
            currentIndex: _tabIndex,
            onTap: _onTabSelected,
            backgroundColor: VColors.background,
            activeColor: VColors.accent,
            inactiveColor: VColors.inactive,
            border: const Border(
              top: BorderSide(color: VColors.border, width: 0.5),
            ),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.play_rectangle),
                label: 'Library',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.square_arrow_up),
                label: 'Upload',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
