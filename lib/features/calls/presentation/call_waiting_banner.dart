import 'package:flutter/material.dart';

class CallWaitingBanner extends StatelessWidget {
  const CallWaitingBanner({
    required this.callerName,
    required this.onView,
    super.key,
  });

  final String callerName;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Card(
        margin: EdgeInsets.zero,
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.phone_in_talk_outlined, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Incoming call', style: theme.textTheme.labelLarge),
                    Text(
                      callerName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: onView, child: const Text('View')),
            ],
          ),
        ),
      ),
    );
  }
}
