import 'package:flutter/material.dart';

import 'theme.dart';

/// Every keyboard shortcut in the app (F1 or Ctrl+/ anywhere).
const shortcutGroups = <(String, List<(String, String)>)>[
  (
    'Everywhere',
    [
      ('F1  or  Ctrl + /', 'Show these shortcuts'),
      ('Tab  /  Shift + Tab', 'Move between controls'),
      ('Enter  or  Space', 'Press the focused button'),
      ('Esc', 'Close a dialog or menu'),
    ],
  ),
  (
    'Navigation',
    [
      ('Alt + Left  /  Alt + Right', 'Back / forward'),
      ('Mouse back / forward buttons', 'Back / forward'),
      ('Ctrl + K  or  Ctrl + P', 'Go to a page by name'),
      ('Ctrl + 0', 'Home (the bento overview)'),
      ('Ctrl + 1 … 3', 'Open Library, Analysis or Crates'),
      (
        'Ctrl + Tab / Ctrl + Shift + Tab',
        'Next or previous tab in a hub (also Ctrl + Page Down / Up)',
      ),
      ('Mouse wheel over the tabs', 'Switch tabs'),
      ('Right-click a Home tile', 'Its links as a menu'),
      ('Ctrl + ,', 'Settings'),
    ],
  ),
  (
    'Library',
    [
      ('Click', 'Select a song'),
      ('Ctrl + click', 'Add or remove a song from the selection'),
      ('Shift + click', 'Select a range'),
      ('Double-click  or  Enter', 'Open the song’s details'),
      (
        'Right-click',
        'Menu: details, crate, analyse online, select all, invert, remove',
      ),
      ('Up / Down', 'Move the selection'),
      ('Shift + Up / Down', 'Grow the selection'),
      ('Page Up / Page Down  ·  Home / End', 'Jump through the list'),
      ('Shift + Home / End', 'Select to the top / bottom'),
      ('Ctrl + A', 'Select all songs in this view'),
      ('Ctrl + I', 'Invert the selection'),
      ('Esc', 'Clear the selection'),
      ('Delete', 'Remove the selected songs from the library (asks first)'),
      ('Ctrl + F', 'Search'),
    ],
  ),
];

Future<void> showShortcuts(BuildContext context) => showDialog<void>(
  context: context,
  builder: (c) {
    final t = DjTokens.of(c);
    final text = Theme.of(c).textTheme;
    return AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (group, keys) in shortcutGroups) ...[
                Padding(
                  padding: const EdgeInsets.only(
                    top: Space.x3,
                    bottom: Space.x2,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(group.toUpperCase(), style: text.labelSmall),
                  ),
                ),
                for (final (key, what) in keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Text(
                            key,
                            style: text.bodyMedium?.copyWith(
                              color: t.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.x3),
                        Expanded(
                          flex: 6,
                          child: Text(
                            what,
                            style: text.bodyMedium?.copyWith(color: t.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Close'),
        ),
      ],
    );
  },
);
