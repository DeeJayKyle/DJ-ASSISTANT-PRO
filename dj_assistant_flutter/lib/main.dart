import 'dart:async';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/accounts.dart';
import 'core/diag_log.dart';
import 'online/http_online.dart' show appVersion;
import 'ui/shell.dart';
import 'ui/state.dart';
import 'ui/theme.dart';
import 'ui/updates.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  DiagLog.init(defaultDataDir());
  DiagLog.info('app', 'DJ Assistant $appVersion');
  final flutterError = FlutterError.onError;
  FlutterError.onError = (d) {
    DiagLog.error('ui', d.exceptionAsString(), d.stack);
    flutterError?.call(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    DiagLog.error('uncaught', e, st);
    return false;
  };
  final accounts = AccountsService.open(defaultDataDir());
  runApp(
    ProviderScope(
      overrides: [accountsProvider.overrideWithValue(accounts)],
      child: const DjAssistantApp(),
    ),
  );
}

class DjAssistantApp extends ConsumerStatefulWidget {
  const DjAssistantApp({super.key, this.checkUpdates = true});

  /// Off in tests (the check is the app's only automatic network call, and
  /// only runs while "Updates" is on in Settings).
  final bool checkUpdates;

  @override
  ConsumerState<DjAssistantApp> createState() => _DjAssistantAppState();
}

class _DjAssistantAppState extends ConsumerState<DjAssistantApp> {
  AppLifecycleListener? _life;
  Timer? _recheck;

  @override
  void initState() {
    super.initState();
    if (widget.checkUpdates) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
      // a long session still picks up a release
      _recheck = Timer.periodic(
        const Duration(hours: 6),
        (_) => _checkUpdate(),
      );
      _life = AppLifecycleListener(
        onExitRequested: () async {
          if (ref.read(settingsProvider)['auto_install_update'] == true) {
            await installOnExit();
          }
          return AppExitResponse.exit;
        },
      );
    }
  }

  @override
  void dispose() {
    _recheck?.cancel();
    _life?.dispose();
    super.dispose();
  }

  Future<void> _checkUpdate() async {
    final settings = ref.read(settingsProvider);
    if (settings['auto_update'] != true) return;
    await autoUpdate(install: settings['auto_install_update'] == true);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final light = settings['theme'] == 'light';
    return MaterialApp(
      title: 'DJ Assistant',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: djTheme(
        light: light,
        accent: '${settings['accent'] ?? 'mint'}',
        glass: settings['surface'] != 'solid',
      ),
      themeAnimationDuration: settings['motion'] == 'reduced'
          ? Duration.zero
          : const Duration(milliseconds: Motion.baseMs),
      builder: (context, child) =>
          Motion(reduced: settings['motion'] == 'reduced', child: child!),
      home: const Shell(),
    );
  }
}
