import 'package:flutter/material.dart';

import 'theme.dart';

/// Every keyboard shortcut in the app (F1 or Ctrl+/ anywhere).
const shortcutGroups = <(String, List<(String, String)>)>[
  (
    'Everywhere',
    [
      ('F1  or  Ctrl + /', 'Show these shortcuts'),
      ('Ctrl + J', 'Open or close the assistant'),
      ('Tab  /  Shift + Tab', 'Move between controls'),
      ('Enter  or  Space', 'Press the focused button'),
      ('Esc', 'Close a dialog or menu'),
    ],
  ),
  (
    'Remix',
    [
      ('Ctrl + Z', 'Undo'),
      ('Ctrl + Shift + Z  or  Ctrl + Y', 'Redo'),
      ('Ctrl + D', 'Duplicate the selected clip'),
      ('Delete', 'Remove the selected clip'),
    ],
  ),
  (
    'Synth Lab',
    [
      (
        'A W S E D F T G Y H U J K O L P ;',
        'Play notes (like a piano keyboard)',
      ),
      ('Z  /  X', 'Octave down / up'),
    ],
  ),
  ('Drum Lab', [('The key shown on each pad', 'Play that pad')]),
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
