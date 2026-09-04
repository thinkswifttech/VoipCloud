import 'package:flutter/material.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 40,
    this.semanticLabel = 'ThinkSwift logo',
  });

  static const assetPath = 'assets/brand/ts_motif_mark.png';

  final double size;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: semanticLabel,
    );
  }
}
