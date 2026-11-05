import 'package:dj_assistant/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the shell shows the sidebar and switches pages', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: DjAssistantApp()));
    expect(find.text('DJ Assistant'), findsOneWidget);
    expect(find.text('CREATE'), findsOneWidget);
    await tester.tap(find.text('DJ Decks'));
    await tester.pump();
    expect(find.widgetWithText(Column, 'DJ Decks'), findsWidgets);
  });
}
