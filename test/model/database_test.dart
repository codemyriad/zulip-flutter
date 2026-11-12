import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/model/database.dart';
import 'package:zulip/model/settings.dart';

import '../example_data.dart' as eg;
import 'schemas/schema.dart';
import 'schemas/schema_v1.dart' as v1;
import 'schemas/schema_v3.dart' as v3;
import 'schemas/schema_v4.dart' as v4;
import 'schemas/schema_v5.dart' as v5;
import 'schemas/schema_v10.dart' as v10;
import 'schemas/schema_v11.dart' as v11;
import 'store_checks.dart';

void main() {
  group('non-migration tests', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });
    tearDown(() async {
      await db.close();
    });

    test('setupDatabaseConnection sets busy_timeout', () async {
      final db = AppDatabase(NativeDatabase.memory(
        setup: setupDatabaseConnection));
      addTearDown(db.close);
      final result = await db.customSelect('PRAGMA busy_timeout').getSingle();
      check(result.data).deepEquals({'timeout': 3000});
    });

    test('initialize GlobalSettings with defaults', () async {
      check(await db.getGlobalSettings()).themeSetting.isNull();
    });

    test('does not crash if multiple global settings rows', () async {
      await db.into(db.globalSettings)
        .insert(const GlobalSettingsCompanion(themeSetting: Value(ThemeSetting.dark)));

      check(await db.select(db.globalSettings).get()).length.equals(2);
      check(await db.getGlobalSettings()).themeSetting.isNull();
    });

    test('GlobalSettings updates work', () async {
      check(await db.getGlobalSettings()).themeSetting.isNull();

      // As in doUpdateGlobalSettings.
      await db.update(db.globalSettings)
        .write(GlobalSettingsCompanion(themeSetting: Value(ThemeSetting.dark)));
      check(await db.getGlobalSettings()).themeSetting.equals(ThemeSetting.dark);
    });

    group('BoolGlobalSettings', () {
      test('get ignores unknown names', () async {
        await db.into(db.boolGlobalSettings)
          .insert(BoolGlobalSettingRow(name: 'nonsense', value: true));
        check(await db.getBoolGlobalSettings()).isEmpty();

        final setting = BoolGlobalSetting.placeholderIgnore;
        await db.into(db.boolGlobalSettings)
          .insert(BoolGlobalSettingRow(name: setting.name, value: true));
        check(await db.getBoolGlobalSettings())
          .deepEquals({setting: true});
      });

      test('insert, then get', () async {
        check(await db.getBoolGlobalSettings()).isEmpty();

        // As in doSetBoolGlobalSetting for `value` non-null.
        final setting = BoolGlobalSetting.placeholderIgnore;
        await db.into(db.boolGlobalSettings).insertOnConflictUpdate(
          BoolGlobalSettingRow(name: setting.name, value: true));
        check(await db.getBoolGlobalSettings())
          .deepEquals({setting: true});
        check(await db.select(db.boolGlobalSettings).get()).length.equals(1);
      });

      test('delete, then get', () async {
        final setting = BoolGlobalSetting.placeholderIgnore;
        await db.into(db.boolGlobalSettings).insertOnConflictUpdate(
          BoolGlobalSettingRow(name: setting.name, value: true));
        check(await db.getBoolGlobalSettings())
          .deepEquals({setting: true});

        // As in doSetBoolGlobalSetting for `value` null.
        final query = db.delete(db.boolGlobalSettings)
          ..where((r) => r.name.equals(setting.name));
        await query.go();
        check(await db.getBoolGlobalSettings()).isEmpty();
        check(await db.select(db.boolGlobalSettings).get()).isEmpty();
      });

      test('insert replaces', () async {
        final setting = BoolGlobalSetting.placeholderIgnore;
        await db.into(db.boolGlobalSettings).insertOnConflictUpdate(
          BoolGlobalSettingRow(name: setting.name, value: true));
        check(await db.getBoolGlobalSettings())
          .deepEquals({setting: true});

        // As in doSetBoolGlobalSetting for `value` non-null.
        await db.into(db.boolGlobalSettings).insertOnConflictUpdate(
          BoolGlobalSettingRow(name: setting.name, value: false));
        check(await db.getBoolGlobalSettings())
          .deepEquals({setting: false});
        check(await db.select(db.boolGlobalSettings).get()).length.equals(1);
      });

      test('delete is idempotent', () async {
        check(await db.getBoolGlobalSettings()).isEmpty();

        // As in doSetBoolGlobalSetting for `value` null.
        final setting = BoolGlobalSetting.placeholderIgnore;
        final query = db.delete(db.boolGlobalSettings)
          ..where((r) => r.name.equals(setting.name));
        await query.go();
        // (No error occurred, even though there was nothing to delete.)
        check(await db.getBoolGlobalSettings()).isEmpty();
        check(await db.select(db.boolGlobalSettings).get()).isEmpty();
      });
    });

    group('IntGlobalSettings', () {
      test('get ignores unknown names', () async {
        await db.into(db.intGlobalSettings)
          .insert(IntGlobalSettingRow(name: 'nonsense', value: 1));
        check(await db.getIntGlobalSettings()).isEmpty();

        final setting = IntGlobalSetting.placeholderIgnore;
        await db.into(db.intGlobalSettings)
          .insert(IntGlobalSettingRow(name: setting.name, value: 1));
        check(await db.getIntGlobalSettings())
          .deepEquals({setting: 1});
      });

      test('insert, then get', () async {
        check(await db.getIntGlobalSettings()).isEmpty();

        // As in doSetIntGlobalSetting for `value` non-null.
        final setting = IntGlobalSetting.placeholderIgnore;
        await db.into(db.intGlobalSettings).insertOnConflictUpdate(
          IntGlobalSettingRow(name: setting.name, value: 1));
        check(await db.getIntGlobalSettings())
          .deepEquals({setting: 1});
        check(await db.select(db.intGlobalSettings).get()).length.equals(1);
      });

      test('delete, then get', () async {
        final setting = IntGlobalSetting.placeholderIgnore;
        await db.into(db.intGlobalSettings).insertOnConflictUpdate(
          IntGlobalSettingRow(name: setting.name, value: 1));
        check(await db.getIntGlobalSettings()).deepEquals({setting: 1});

        // As in doSetIntGlobalSetting for `value` null.
        final query = db.delete(db.intGlobalSettings)
          ..where((r) => r.name.equals(setting.name));
        await query.go();
        check(await db.getIntGlobalSettings()).isEmpty();
        check(await db.select(db.intGlobalSettings).get()).isEmpty();
      });

      test('insert replaces', () async {
        final setting = IntGlobalSetting.placeholderIgnore;
        await db.into(db.intGlobalSettings).insertOnConflictUpdate(
          IntGlobalSettingRow(name: setting.name, value: 1));
        check(await db.getIntGlobalSettings())
          .deepEquals({setting: 1});

        // As in doSetIntGlobalSetting for `value` non-null.
        await db.into(db.intGlobalSettings).insertOnConflictUpdate(
          IntGlobalSettingRow(name: setting.name, value: 2));
        check(await db.getIntGlobalSettings())
          .deepEquals({setting: 2});
        check(await db.select(db.intGlobalSettings).get()).length.equals(1);
      });

      test('delete is idempotent', () async {
        check(await db.getIntGlobalSettings()).isEmpty();

        // As in doSetIntGlobalSetting for `value` null.
        final setting = IntGlobalSetting.placeholderIgnore;
        final query = db.delete(db.intGlobalSettings)
          ..where((r) => r.name.equals(setting.name));
        await query.go();
        // (No error occurred, even though there was nothing to delete.)
        check(await db.getIntGlobalSettings()).isEmpty();
        check(await db.select(db.intGlobalSettings).get()).isEmpty();
      });
    });

    test('create account', () async {
      final accountData = AccountsCompanion.insert(
        realmUrl: Uri.parse('https://chat.example/'),
        realmName: Value('Example Zulip organization'),
        realmIcon: Value(Uri.parse('/user_avatars/2/realm/icon.png?version=3')),
        userId: 1,
        email: 'asdf@example.org',
        apiKey: '1234',
        zulipVersion: '6.0',
        zulipMergeBase: const Value('6.0'),
        zulipFeatureLevel: 42,
        possibleLegacyPushToken: Value(false),
      );
      final accountId = await db.createAccount(accountData);
      final account = await (db.select(db.accounts)
            ..where((a) => a.id.equals(accountId)))
          .watchSingle()
          .first;
      check(account.toCompanion(false).toJson()).deepEquals({
        ...accountData.toJson(),
        'id': (Subject<Object?> it) => it.isA<int>(),
        'device_id': null,
        'possible_legacy_push_token': false,
      });
    });

    test('create account with same realm and userId ', () async {
      final accountData = AccountsCompanion.insert(
        realmUrl: Uri.parse('https://chat.example/'),
        userId: 1,
        email: 'asdf@example.org',
        apiKey: '1234',
        zulipVersion: '6.0',
        zulipMergeBase: const Value('6.0'),
        zulipFeatureLevel: 42,
      );
      final accountDataWithSameUserId = AccountsCompanion.insert(
        realmUrl: Uri.parse('https://chat.example/'),
        userId: 1,
        email: 'otheremail@example.org',
        apiKey: '12345',
        zulipVersion: '6.0',
        zulipMergeBase: const Value('6.0'),
        zulipFeatureLevel: 42,
      );
      await db.createAccount(accountData);
      await check(db.createAccount(accountDataWithSameUserId))
        .throws<AccountAlreadyExistsException>();
    });

    test('create account with same realm and email', () async {
      final accountData = AccountsCompanion.insert(
        realmUrl: Uri.parse('https://chat.example/'),
        userId: 1,
        email: 'asdf@example.org',
        apiKey: '1234',
        zulipVersion: '6.0',
        zulipMergeBase: const Value('6.0'),
        zulipFeatureLevel: 42,
      );
      final accountDataWithSameEmail = AccountsCompanion.insert(
        realmUrl: Uri.parse('https://chat.example/'),
        userId: 2,
        email: 'asdf@example.org',
        apiKey: '12345',
        zulipVersion: '6.0',
        zulipMergeBase: const Value('6.0'),
        zulipFeatureLevel: 42,
      );
      await db.createAccount(accountData);
      await check(db.createAccount(accountDataWithSameEmail))
        .throws<AccountAlreadyExistsException>();
    });

    test('create push key', () async {
      await db.createAccount(eg.selfAccount.toCompanion(false));
      final pushKeyData = eg.pushKey(account: eg.selfAccount).toCompanion(false);
      await db.createPushKey(pushKeyData);
      final pushKey = await db.select(db.pushKeys).getSingle();
      check(pushKey.toCompanion(false).toJson()).deepEquals(pushKeyData.toJson());
    });

    test('create push key with duplicate pushKeyId', () async {
      await db.createAccount(eg.selfAccount.toCompanion(false));
      final pushKey = eg.pushKey(account: eg.selfAccount);
      await db.createPushKey(pushKey.toCompanion(false));

      // Duplicates not allowed on the same account…
      await check(db.createPushKey(eg.pushKey(account: eg.selfAccount,
        pushKeyId: pushKey.pushKeyId,
      ).toCompanion(false)))
        .throws<PushKeyAlreadyExistsException>();

      // … nor a different one.
      await db.createAccount(eg.otherAccount.toCompanion(false));
      await check(db.createPushKey(eg.pushKey(account: eg.otherAccount,
        pushKeyId: pushKey.pushKeyId,
      ).toCompanion(false)))
        .throws<PushKeyAlreadyExistsException>();
    });

    test('delete account cascades to push key', () async {
      await db.createAccount(eg.selfAccount.toCompanion(false));
      final pushKey = eg.pushKey(account: eg.selfAccount);
      await db.createPushKey(pushKey.toCompanion(false));
      check(await db.select(db.pushKeys).get()).length.equals(1);

      await (db.delete(db.accounts)..where((a) => a.id.equals(eg.selfAccount.id)))
        .go();
      check(await db.select(db.pushKeys).get()).isEmpty();
    });

    group('server data', () {
      Future<void> prepare() async {
        await db.createAccount(eg.selfAccount.toCompanion(false));
        await db.createAccount(eg.otherAccount.toCompanion(false));
      }

      Future<bool> append(Account account, int lastEventId, String? data, {
        String queueId = 'queue1',
      }) {
        return db.appendServerEvents(account.id,
          queueId: queueId, lastEventId: lastEventId,
          data: data == null ? null : utf8.encode(data));
      }

      Future<ServerData?> load(Account account) => db.loadServerData(account.id);

      Condition<Object?> isBatch(int lastEventId, String data) {
        return (it) => it.isA<ServerEventBatch>()
          ..accountId.equals(eg.selfAccount.id)
          ..queueId.equals('queue1')
          ..lastEventId.equals(lastEventId)
          ..data.deepEquals(utf8.encode(data));
      }

      test('store snapshot, then load', () async {
        await prepare();
        final snapshot = eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10);
        check(await db.storeServerSnapshot(snapshot)).isTrue();
        check(await load(eg.selfAccount)).isNotNull()
          ..snapshot.equals(snapshot)
          ..eventBatches.isEmpty();
        check(await load(eg.otherAccount)).isNull();
      });

      test('no store snapshot when account missing', () async {
        await db.createAccount(eg.otherAccount.toCompanion(false));
        check(await db.storeServerSnapshot(
          eg.serverSnapshot(account: eg.selfAccount))).isFalse();
        check(await db.select(db.serverSnapshots).get()).isEmpty();
      });

      test('store snapshot replaces snapshot and its batches', () async {
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10));
        await append(eg.selfAccount, 11, '[{"id":11}]');
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.otherAccount,
          queueId: 'queue1', lastEventId: 10));
        await append(eg.otherAccount, 11, '[{"id":11}]');

        final newSnapshot = eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue2', lastEventId: 20);
        check(await db.storeServerSnapshot(newSnapshot)).isTrue();
        check(await load(eg.selfAccount)).isNotNull()
          ..snapshot.equals(newSnapshot)
          ..eventBatches.isEmpty();
        check(await db.select(db.serverSnapshots).get()).length.equals(2);
        check(await db.select(db.serverEventBatches).get())
          .single.accountId.equals(eg.otherAccount.id);
      });

      test('append events with data', () async {
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10));
        check(await append(eg.selfAccount, 12, '[{"id":11},{"id":12}]')).isTrue();
        check(await load(eg.selfAccount)).isNotNull()
          ..snapshot.lastEventId.equals(12)
          ..eventBatches.deepEquals([isBatch(12, '[{"id":11},{"id":12}]')]);
      });

      test('append events without data advances lastEventId only', () async {
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10));
        check(await append(eg.selfAccount, 12, null)).isTrue();
        check(await load(eg.selfAccount)).isNotNull()
          ..snapshot.lastEventId.equals(12)
          ..eventBatches.isEmpty();
        check(await db.select(db.serverEventBatches).get()).isEmpty();
      });

      test('no append events for another queue', () async {
        await prepare();
        final snapshot = eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10);
        await db.storeServerSnapshot(snapshot);
        await append(eg.selfAccount, 11, '[{"id":11}]');

        check(await append(eg.selfAccount, 12, '[{"id":12}]', queueId: 'queue0'))
          .isFalse();
        check(await append(eg.selfAccount, 13, null, queueId: 'queue0'))
          .isFalse();
        check(await load(eg.selfAccount)).isNotNull()
          ..snapshot.lastEventId.equals(11)
          ..eventBatches.deepEquals([isBatch(11, '[{"id":11}]')]);
        check(await db.select(db.serverEventBatches).get()).length.equals(1);
      });

      test('no append events without snapshot', () async {
        await prepare();
        check(await append(eg.selfAccount, 11, '[{"id":11}]')).isFalse();
        check(await db.select(db.serverEventBatches).get()).isEmpty();
      });

      test('no append events when account missing', () async {
        check(await append(eg.selfAccount, 11, '[{"id":11}]')).isFalse();
        check(await db.select(db.serverEventBatches).get()).isEmpty();
      });

      test('load data gives event batches in order', () async {
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10));
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.otherAccount,
          queueId: 'queue1', lastEventId: 10));
        await append(eg.selfAccount, 11, '[{"id":11}]');
        await append(eg.otherAccount, 11, '[{"id":11}]');
        await append(eg.selfAccount, 12, null);
        await append(eg.selfAccount, 14, '[{"id":13},{"id":14}]');
        await append(eg.selfAccount, 15, '[{"id":15}]');
        check(await load(eg.selfAccount)).isNotNull()
          ..snapshot.lastEventId.equals(15)
          ..eventBatches.deepEquals([
            isBatch(11, '[{"id":11}]'),
            isBatch(14, '[{"id":13},{"id":14}]'),
            isBatch(15, '[{"id":15}]'),
          ]);
      });

      test('load data without event batches', () async {
        await prepare();
        final snapshot = eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10);
        await db.storeServerSnapshot(snapshot);
        await append(eg.selfAccount, 11, '[{"id":11}]');
        check(await db.loadServerData(eg.selfAccount.id, includeEventBatches: false))
          .isNotNull()
          ..snapshot.equals(snapshot.copyWith(lastEventId: 11))
          ..eventBatches.isEmpty();
      });

      test('load ignores event batches of other queues', () async {
        // The other methods don't leave any such batches,
        // but loading doesn't rely on that.
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10));
        await append(eg.selfAccount, 11, '[{"id":11}]');
        await db.into(db.serverEventBatches).insert(ServerEventBatchesCompanion.insert(
          accountId: eg.selfAccount.id, queueId: 'queue0', lastEventId: 9,
          data: utf8.encode('[{"id":9}]')));
        check(await load(eg.selfAccount)).isNotNull()
          .eventBatches.deepEquals([isBatch(11, '[{"id":11}]')]);
        check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).isNotNull()
          .has((x) => x.eventBatchesSize, 'eventBatchesSize')
          .equals(utf8.encode('[{"id":11}]').length);
      });

      test('load snapshot info', () async {
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10,
          appVersion: '2.0.0+3', timestamp: 1771389742,
          data: utf8.encode('{"queue_id":"queue1","last_event_id":10}')));
        check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).equals((
          queueId: 'queue1', lastEventId: 10,
          appVersion: '2.0.0+3', timestamp: 1771389742,
          snapshotSize: 40, eventBatchesSize: 0,
        ));

        await append(eg.selfAccount, 11, '[{"id":11}]');
        await append(eg.selfAccount, 12, null);
        await append(eg.selfAccount, 14, '[{"id":13},{"id":14}]');
        check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).equals((
          queueId: 'queue1', lastEventId: 14,
          appVersion: '2.0.0+3', timestamp: 1771389742,
          snapshotSize: 40, eventBatchesSize: 11 + 21,
        ));
      });

      test('load snapshot info, no snapshot', () async {
        await prepare();
        check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).isNull();
      });

      test('clear server data', () async {
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10));
        await append(eg.selfAccount, 11, '[{"id":11}]');
        final otherSnapshot = eg.serverSnapshot(account: eg.otherAccount,
          queueId: 'queue1', lastEventId: 10);
        await db.storeServerSnapshot(otherSnapshot);
        await append(eg.otherAccount, 11, '[{"id":11}]');

        await db.clearServerData(eg.selfAccount.id);
        check(await load(eg.selfAccount)).isNull();
        check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).isNull();
        check(await load(eg.otherAccount)).isNotNull()
          ..snapshot.equals(otherSnapshot.copyWith(lastEventId: 11))
          ..eventBatches.length.equals(1);
        check(await db.select(db.serverEventBatches).get())
          .single.accountId.equals(eg.otherAccount.id);

        // Clearing again is a no-op.
        await db.clearServerData(eg.selfAccount.id);
        check(await load(eg.otherAccount)).isNotNull();
      });

      test('delete account cascades to server data', () async {
        await prepare();
        await db.storeServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10));
        await append(eg.selfAccount, 11, '[{"id":11}]');
        check(await db.select(db.serverSnapshots).get()).length.equals(1);
        check(await db.select(db.serverEventBatches).get()).length.equals(1);

        await (db.delete(db.accounts)..where((a) => a.id.equals(eg.selfAccount.id)))
          .go();
        check(await db.select(db.serverSnapshots).get()).isEmpty();
        check(await db.select(db.serverEventBatches).get()).isEmpty();
      });
    });
  });

  group('migrations', () {
    late SchemaVerifier verifier;

    setUpAll(() {
      verifier = SchemaVerifier(GeneratedHelper());
    });

    test('downgrading', () async {
      final toVersion = AppDatabase.latestSchemaVersion;
      final schema = await verifier.schemaAt(toVersion);

      // This simulates the scenario during development when running the app
      // with a future schema version that has additional tables and columns.
      final before = AppDatabase(schema.newConnection());
      await before.customStatement('CREATE TABLE test_extra (num int)');
      await before.customStatement('ALTER TABLE accounts ADD extra_column int');
      await check(verifier.migrateAndValidate(before, toVersion,
        options: const ValidationOptions(validateDropped: true))).throws<SchemaMismatch>();
      // Override the schema version by modifying the underlying value
      // drift internally keeps track of in the database.
      // TODO(drift): Expose a better interface for testing this.
      await before.customStatement('PRAGMA user_version = ${toVersion + 1};');
      await before.close();

      // Simulate starting up the app, with an older schema version that
      // does not have the extra tables and columns.
      final after = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(after, toVersion,
        options: const ValidationOptions(validateDropped: true));
      // Check that a custom migration/setup step of ours got run too.
      check(await after.getGlobalSettings()).themeSetting.isNull();
      await after.close();
    });

    group('migrate without data', () {
      const versions = GeneratedHelper.versions;
      final latestVersion = versions.last;

      int prev = versions.first;
      for (final toVersion in versions.skip(1)) {
        final fromVersion = prev;
        test('from v$fromVersion to v$toVersion', () async {
          final connection = await verifier.startAt(fromVersion);
          final db = AppDatabase(connection);
          await verifier.migrateAndValidate(db, toVersion);
          await db.close();
        });
        prev = toVersion;
      }

      for (final fromVersion in versions) {
        if (fromVersion == latestVersion) break;
        test('from v$fromVersion to latest (v$latestVersion)', () async {
          final connection = await verifier.startAt(fromVersion);
          final db = AppDatabase(connection);
          await verifier.migrateAndValidate(db, latestVersion);
          await db.close();
        });
      }
    });

    test('migrate existing GlobalSettings row', () async {
      // This tests several migrations that apply to GlobalSettings and
      // don't interact with each other.
      final schema = await verifier.schemaAt(3);
      final before = v3.DatabaseAtV3(schema.newConnection());
      await before.into(before.globalSettings).insert(
        v3.GlobalSettingsCompanion.insert(
          themeSetting: Value(ThemeSetting.light.name)));
      await before.close();

      final after = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(after, AppDatabase.latestSchemaVersion);
      final globalSettings = await after.select(after.globalSettings).getSingle();
      check(globalSettings.toJson()).deepEquals({
        'themeSetting': ThemeSetting.light.name,
        'browserPreference': null, // v4
        // (v5 has no effect when a GlobalSettings row already exists)
        'visitFirstUnread': null, // v7
        'markReadOnScroll': null, // v8
        'legacyUpgradeState': 'noLegacy', // v9
      });
      await after.close();
    });

    test('migrate existing Account row', () async {
      // This tests several migrations that apply to Accounts and
      // don't interact with each other.
      final schema = await verifier.schemaAt(1);
      final before = v1.DatabaseAtV1(schema.newConnection());
      await before.into(before.accounts).insert(v1.AccountsCompanion.insert(
        realmUrl: 'https://chat.example/',
        userId: 1,
        email: 'asdf@example.org',
        apiKey: '1234',
        zulipVersion: '6.0',
        zulipMergeBase: const Value('6.0'),
        zulipFeatureLevel: 42,
      ));
      final accountV1 = await before.select(before.accounts).watchSingle().first;
      await before.close();

      final after = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(after, AppDatabase.latestSchemaVersion);
      final account = await after.select(after.accounts).getSingle();
      check(account.toJson()).deepEquals({
        ...accountV1.toJson(),
        'realmUrl': Uri.parse(accountV1.realmUrl), // TODO(drift): type mismatch between latest and test schemas

        // 'ackedPushToken': null, // added in v2, removed in v15; was always null
        'realmName': null, 'realmIcon': null, // v12
        'deviceId': null, // v13
        'possibleLegacyPushToken': true, // v16
      });
      await after.close();
    });

    // v2 covered by "existing Account row" above

    // v3 only adds a new table; the "migrate without data" test covers it

    // v4 covered by "existing GlobalSettings row" above

    // v5 partly covered by "existing GlobalSettings row" above

    test('upgrade to v5: with no existing GlobalSettings row, insert one', () async {
      final schema = await verifier.schemaAt(4);
      final before = v4.DatabaseAtV4(schema.newConnection());
      check(await before.select(before.globalSettings).get()).isEmpty();
      await before.close();

      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 5);
      await db.close();

      final after = v5.DatabaseAtV5(schema.newConnection());
      final globalSettings = await after.select(after.globalSettings).getSingle();
      check(globalSettings.themeSetting).isNull();
      check(globalSettings.browserPreference).isNull();
      await after.close();
    });

    // v6 only adds a new table; the "migrate without data" test covers it

    // v7 covered by "existing GlobalSettings row" above

    // v8 covered by "existing GlobalSettings row" above

    // v9 covered by "existing GlobalSettings row" above

    // v10 only adds a new table; the "migrate without data" test covers it

    test('upgrade to v11: with accounts available, '
        'insert first account ID as the last-visited account ID', () async {
      final schema = await verifier.schemaAt(10);
      final before = v10.DatabaseAtV10(schema.newConnection());
      final firstAccountId = await before.into(before.accounts).insert(
        v10.AccountsCompanion.insert(
          realmUrl: 'https://chat.example/',
          userId: 1,
          email: 'asdf@example.org',
          apiKey: '1234',
          zulipVersion: '10.0',
          zulipMergeBase: const Value('10.0'),
          zulipFeatureLevel: 370,
        ));
      await before.into(before.accounts).insert(
        v10.AccountsCompanion.insert(
          realmUrl: 'https://example.com/',
          userId: 2,
          email: 'jkl@example.com',
          apiKey: '4321',
          zulipVersion: '11.0',
          zulipMergeBase: const Value('11.0'),
          zulipFeatureLevel: 420,
        ));
      await before.close();

      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 11);
      await db.close();

      final after = v11.DatabaseAtV11(schema.newConnection());
      final intGlobalSettings = await after.select(after.intGlobalSettings).getSingle();
      check(intGlobalSettings.name).equals(IntGlobalSetting.lastVisitedAccountId.name);
      check(intGlobalSettings.value).equals(firstAccountId);
      await after.close();
    });

    test("upgrade to v11: with no accounts available, don't set last-visited account ID", () async {
      final schema = await verifier.schemaAt(10);
      final before = v10.DatabaseAtV10(schema.newConnection());
      check(await before.select(before.accounts).get()).isEmpty();
      await before.close();

      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 11);
      await db.close();

      final after = v11.DatabaseAtV11(schema.newConnection());
      check(await after.select(after.intGlobalSettings).get()).isEmpty();
      await after.close();
    });

    // v12 covered by "existing Account row" above

    // v13 covered by "existing Account row" above

    // v14 only adds a new table; the "migrate without data" test covers it

    // v15 covered by "existing Account row" above

    // v16 covered by "existing Account row" above

    // v17 only adds new tables; the "migrate without data" test covers it
  });
}

extension UpdateCompanionExtension<T> on UpdateCompanion<T> {
  Map<String, Object?> toJson() {
    // Compare sketches of this idea in discussion at:
    //   https://github.com/simolus3/drift/issues/1924
    // To go upstream, this would need to handle DateTime
    // and Uint8List variables, and would need a fromJson.
    // Also should document that the keys are column names,
    // not Dart field names.  (The extension is on UpdateCompanion
    // rather than Insertable to avoid confusion with the toJson
    // on DataClass row classes, which use Dart field names.)
    return {
      for (final kv in toColumns(false).entries)
        kv.key: (kv.value as Variable).value
    };
  }
}
