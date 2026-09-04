import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import 'caller_identity.dart';

/// Photo → initials (named party) → person icon (number-only).
class CallerAvatar extends StatelessWidget {
  const CallerAvatar({
    required this.identity,
    this.radius = 56,
    this.backgroundColor,
    this.foregroundColor,
    super.key,
  });

  final CallerIdentity identity;
  final double radius;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = identity.photo;
    final decodeSize = (radius * 4).round().clamp(128, 512);
    final initials = identity.initials;

    Widget? child;
    if (photo == null) {
      if (identity.isResolvedName && initials.isNotEmpty) {
        child = Text(
          initials,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontFamily: AppTheme.bodyFontFamily,
            color: foregroundColor ?? AppTheme.avatarForeground,
            fontWeight: FontWeight.w700,
            fontSize: radius * 0.58,
            letterSpacing: 0,
          ),
        );
      } else {
        child = Icon(
          AppIcons.person,
          size: radius * 1.05,
          color: foregroundColor ?? AppTheme.avatarForeground,
        );
      }
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor:
          backgroundColor ?? AppTheme.avatarBackground(theme.brightness),
      foregroundColor: foregroundColor ?? AppTheme.avatarForeground,
      backgroundImage: photo == null
          ? null
          : ResizeImage(
              MemoryImage(photo),
              width: decodeSize,
              height: decodeSize,
              policy: ResizeImagePolicy.fit,
            ),
      child: child,
    );
  }
}
