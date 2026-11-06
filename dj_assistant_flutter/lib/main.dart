import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/accounts.dart';
import 'core/diag_log.dart';
import 'core/updater.dart';
import 'online/http_online.dart' show HttpOnline, appVersion;
import 'ui/shell.dart';
import 'ui/state.dart';
import 'ui/theme.dart';

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
  @override
  void initState() {
    super.initState();
    if (widget.checkUpdates) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
    }
  }

  Future<void> _checkUpdate() async {
    final settings = ref.read(settingsProvider);
    if (settings['auto_update'] != true) return;
    try {
      final u = await checkForUpdate(HttpOnline().web, appVersion);
      if (u != null) {
        toast('DJ Assistant ${u.version} is available — Settings → Updates.');
      }
    } on Object {
      // offline: try again next start
    }
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
