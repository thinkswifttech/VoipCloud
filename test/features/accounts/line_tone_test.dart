import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';
import 'package:phone_app/features/accounts/presentation/line_tone.dart';

const _lightSurface = Color(0xFFFFFFFF);
const _darkSurface = Color(0xFF111318);

void main() {
  test(
    'every offered colour is readable as text on its own tint, both modes',
    () {
      for (final value in accountColorChoices) {
        for (final (brightness, surface) in [
          (Brightness.light, _lightSurface),
          (Brightness.dark, _darkSurface),
        ]) {
          final tone = LineTone.from(value, brightness, surface);
          expect(
            contrastRatio(tone.onSoft, tone.soft),
            greaterThanOrEqualTo(4.5),
            reason: '0x${value.toRadixString(16)} on its tint in $brightness',
          );
        }
      }
    },
  );

  test('the palette never uses the error, success or warning colours', () {
    // Roughly red, green and amber hues are reserved for status.
    for (final value in accountColorChoices) {
      final hsl = HSLColor.fromColor(Color(value));
      final hue = hsl.hue;
      final isReserved =
          hsl.saturation > 0.35 &&
          (hue < 20 ||
              hue > 345 ||
              (hue > 40 && hue < 70) ||
              (hue > 85 && hue < 150));
      expect(
        isReserved,
        isFalse,
        reason: '0x${value.toRadixString(16)} hue $hue',
      );
    }
  });

  test('colours are distinct enough that two lines are never confused', () {
    final colors = accountColorChoices.map(Color.new).toList();
    for (var i = 0; i < colors.length; i++) {
      for (var j = i + 1; j < colors.length; j++) {
        expect(
          contrastRatio(colors[i], colors[j]) > 1.15 ||
              (HSLColor.fromColor(colors[i]).hue -
                          HSLColor.fromColor(colors[j]).hue)
                      .abs() >
                  25,
          isTrue,
          reason: 'choices $i and $j are too alike',
        );
      }
    }
  });

  test(
    'readableOn keeps a colour that already reads and fixes one that does not',
    () {
      const dark = Color(0xFF0F766E);
      expect(readableOn(dark, _lightSurface), dark);
      const pale = Color(0xFFBFD7FF);
      final fixed = readableOn(pale, _lightSurface);
      expect(contrastRatio(fixed, _lightSurface), greaterThanOrEqualTo(4.5));
      final onDark = readableOn(const Color(0xFF1F3A8A), _darkSurface);
      expect(contrastRatio(onDark, _darkSurface), greaterThanOrEqualTo(4.5));
    },
  );
}
