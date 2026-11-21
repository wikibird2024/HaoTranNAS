/// A problem as the user sees it: one plain sentence, the raw reason in
/// small text under it, and a Try again button. Used wherever a screen
/// would otherwise be a dead end. Author: Hao Tran.
library;

import 'package:flutter/material.dart';

class ProblemView extends StatelessWidget {
  const ProblemView(this.text, {super.key, this.detail, required this.onRetry});

  final String text;

  /// The raw reason, shown small under [text]; null = none.
  final String? detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (detail != null)
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
