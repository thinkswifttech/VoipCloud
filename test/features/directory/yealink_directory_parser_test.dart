import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/yealink_directory_parser.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

void main() {
  test('parses Yealink directory entries and telephone kinds', () {
    const xml = '''
<YealinkIPPhoneDirectory>
  <DirectoryEntry>
    <Name>Example Support</Name>
    <team>Example Accounting</team>
    <team>Example Operations</team>
    <Telephone type="Internal">99</Telephone>
  </DirectoryEntry>
  <DirectoryEntry>
    <Name>Vendor Desk</Name>
    <Company>Northwind Telecom</Company>
    <value>External</value>
    <Telephone>18005550199</Telephone>
    <Telephone>14165550100</Telephone>
  </DirectoryEntry>
</YealinkIPPhoneDirectory>
''';

    final entries = parseYealinkDirectoryXml(xml);

    expect(entries, hasLength(2));
    expect(entries.first.displayName, 'Example Support');
    expect(entries.first.extension, '99');
    expect(entries.first.company, isEmpty);
    expect(entries.first.teams, ['Example Accounting', 'Example Operations']);
    expect(entries.first.telephoneKind, DirectoryTelephoneKind.internal);
    expect(entries.last.telephoneKind, DirectoryTelephoneKind.external);
    expect(entries.last.company, 'Northwind Telecom');
    expect(entries.last.numbers, ['18005550199', '14165550100']);
    expect(entries.map((entry) => entry.presence).toSet(), isNotEmpty);
  });
}
