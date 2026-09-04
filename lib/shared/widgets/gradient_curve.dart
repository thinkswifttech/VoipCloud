import 'dart:math' as math;

import 'package:flutter/material.dart';

class GradientCurve extends StatelessWidget {
  const GradientCurve({
    this.height = 72,
    this.opacity = 1,
    this.flipVertical = false,
    super.key,
  });

  static const assetPath = 'assets/brand/gradient_curve.png';

  final double height;
  final double opacity;
  final bool flipVertical;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      assetPath,
      width: double.infinity,
      height: height,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      semanticLabel: '',
      excludeFromSemantics: true,
    );

    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: flipVertical
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.rotationX(math.pi),
                child: image,
              )
            : image,
      ),
    );
  }
}
