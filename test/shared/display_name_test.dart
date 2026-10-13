import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/presentation/caller_identity.dart';
import 'package:phone_app/shared/utils/display_name.dart';

void main() {
  group('nameWithoutPrefixTag', () {
    test('drops a short tag before the name', () {
      expect(nameWithoutPrefixTag('SUP: Leo Grosso'), 'Leo Grosso');
      expect(nameWithoutPrefixTag('SUP:SAHIL MILLU'), 'SAHIL MILLU');
      expect(nameWithoutPrefixTag('  SUP:  Mayra Grosso '), 'Mayra Grosso');
    });

    test('leaves ordinary names, numbers and URIs alone', () {
      expect(nameWithoutPrefixTag('Leo Grosso'), 'Leo Grosso');
      expect(nameWithoutPrefixTag('4168833878'), '4168833878');
      expect(
        nameWithoutPrefixTag('sip:101@example.test'),
        'sip:101@example.test',
      );
      expect(nameWithoutPrefixTag('Sales Team: West'), 'Sales Team: West');
      expect(nameWithoutPrefixTag('SUP:'), 'SUP:');
      expect(nameWithoutPrefixTag(':x'), ':x');
    });
  });

  test('call identity initials use the name, not the tag', () {
    CallerIdentity identity(String label) => CallerIdentity(
      label: label,
      number: '4168833878',
      isResolvedName: true,
    );
    expect(identity('SUP: Leo Grosso').initials, 'LG');
    expect(identity('SUP:SAHIL MILLU').initials, 'SM');
    expect(identity('Leo Grosso').initials, 'LG');
    expect(identity('Madonna').initials, 'M');
  });
}
