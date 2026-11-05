import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/shell.dart';
import 'ui/theme.dart';

void main() {
  runApp(const ProviderScope(child: DjAssistantApp()));
}

class DjAssistantApp extends StatelessWidget {
  const DjAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DJ Assistant',
      debugShowCheckedModeBanner: false,
      theme: midnightTheme(),
      home: const Shell(),
    );
  }
}
