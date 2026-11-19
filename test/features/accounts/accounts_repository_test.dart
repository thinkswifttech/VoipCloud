import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/accounts/data/accounts_repository.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';

class _MemoryStorage implements SecureStorageService {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll() async => values.clear();
}

const _sipJson = {
  'sipIdentity': 'sip:210@swift.example.test',
  'extension': '210',
  'password': 'secret',
  'registrar': 'sip.example.test',
};

void main() {
  late _MemoryStorage storage;
  late AccountsRepository repository;

  setUp(() {
    storage = _MemoryStorage();
    repository = AccountsRepository(storage);
  });

  group('AccountsPrefs', () {
    test('defaults: ask, blue primary, teal secondary', () {
      const prefs = AccountsPrefs();
      expect(prefs.defaultOutgoing, DefaultOutgoingLine.ask);
      expect(prefs.colorValue(AccountLine.primary), accountColorChoices[0]);
      expect(prefs.colorValue(AccountLine.secondary), accountColorChoices[1]);
    });

    test('a custom name and colour win; an empty name resets to default', () {
      var prefs = const AccountsPrefs().withAppearance(
        AccountLine.secondary,
        const AccountAppearance(label: 'Home office', colorValue: 0xFF22A06B),
      );
      expect(prefs.label(AccountLine.secondary, null), 'Home office');
      expect(prefs.colorValue(AccountLine.secondary), 0xFF22A06B);
      expect(prefs.colorValue(AccountLine.primary), accountColorChoices[0]);

      prefs = prefs.withAppearance(
        AccountLine.secondary,
        prefs.secondary.copyWith(label: '  '),
      );
      expect(prefs.label(AccountLine.secondary, null), 'Second line');
    });

    test('the default name is the extension and the host name', () {
      final config = _secondary().sipConfig;
      expect(defaultLineLabel(config), '210 · swift');
      expect(
        const AccountsPrefs().label(AccountLine.primary, config),
        '210 · swift',
      );
    });

    test('unknown values fall back to ask and to no appearance', () {
      final prefs = AccountsPrefs.fromJson({
        'defaultOutgoing': 'nonsense',
        'primary': 'oops',
      });
      expect(prefs.defaultOutgoing, DefaultOutgoingLine.ask);
      expect(prefs.primary.label, isNull);
    });

    test('maps the default choice to a line', () {
      expect(DefaultOutgoingLine.ask.line, isNull);
      expect(DefaultOutgoingLine.primary.line, AccountLine.primary);
      expect(DefaultOutgoingLine.secondary.line, AccountLine.secondary);
      expect(AccountLine.primary.other, AccountLine.secondary);
    });
  });

  group('AccountsRepository', () {
    test('keeps the second account and the prefs across a restart', () async {
      expect(await repository.readSecondary(), isNull);
      await repository.writeSecondary(_secondary());
      await repository.writePrefs(
        const AccountsPrefs(defaultOutgoing: DefaultOutgoingLine.secondary),
      );

      final reread = AccountsRepository(storage);
      final account = await reread.readSecondary();
      expect(account?.sipConfig.sipIdentity, '210@swift.example.test');
      expect(
        (await reread.readPrefs()).defaultOutgoing,
        DefaultOutgoingLine.secondary,
      );
    });

    test('a damaged record never throws', () async {
      storage.values[StorageKeys.appSecondaryAccount] = '{not json';
      storage.values[StorageKeys.appAccountsPrefs] = '[]';
      expect(await repository.readSecondary(), isNull);
      expect(
        (await repository.readPrefs()).defaultOutgoing,
        DefaultOutgoingLine.ask,
      );
    });

    test(
      'clearing removes the second account; an app reset removes the prefs too',
      () async {
        await repository.writeSecondary(_secondary());
        await repository.writePrefs(const AccountsPrefs());
        await repository.clearSecondary();
        expect(await repository.readSecondary(), isNull);
        expect(
          storage.values.containsKey(StorageKeys.appAccountsPrefs),
          isTrue,
        );
        await repository.clearAll();
        expect(storage.values, isEmpty);
      },
    );
  });
}

SecondaryAccount _secondary() => SecondaryAccount.fromJson({'sip': _sipJson});
