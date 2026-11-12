import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:zulip/model/image_disk_cache.dart';

import 'binding.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  late Directory root;
  late FileImageDiskCache cache;

  const accountId = 1;
  const otherAccountId = 2;
  final url = Uri.parse('https://chat.example/user_uploads/1/ab/x.png');

  Future<void> prepare({int? maxAccountBytes}) async {
    final tempDir = await Directory.systemTemp.createTemp('image_disk_cache_test');
    addTearDown(() => tempDir.delete(recursive: true));
    root = Directory(p.join(tempDir.path, 'images'));
    cache = FileImageDiskCache(
      getRootDirectory: () async => root,
      maxAccountBytes: maxAccountBytes ?? 100 * 1024 * 1024);
  }

  Uri urlN(int n) => Uri.parse('https://chat.example/user_uploads/1/ab/$n.png');

  List<String> filesIn(Directory dir) =>
    dir.listSync().map((e) => p.basename(e.path)).toList();

  test('get absent entry', () async {
    await prepare();
    check(await cache.get(accountId, url)).isNull();
  });

  test('put then get', () async {
    await prepare();
    final bytes = Uint8List.fromList([1, 2, 3]);
    await cache.put(accountId, url, bytes);
    check(await cache.get(accountId, url)).isNotNull().deepEquals(bytes);
  });

  test('put replaces entry', () async {
    await prepare();
    await cache.put(accountId, url, Uint8List.fromList([1, 2, 3]));
    await cache.put(accountId, url, Uint8List.fromList([4, 5]));
    check(await cache.get(accountId, url)).isNotNull().deepEquals([4, 5]);
  });

  test('put leaves no temporary file', () async {
    await prepare();
    await cache.put(accountId, url, Uint8List(10));
    check(filesIn(Directory(p.join(root.path, '$accountId'))))
      .single.not((it) => it.endsWith('.tmp'));
  });

  test('no store larger than 2 MiB', () async {
    await prepare();
    const maxEntryBytes = 2 * 1024 * 1024;
    await cache.put(accountId, urlN(1), Uint8List(maxEntryBytes));
    await cache.put(accountId, urlN(2), Uint8List(maxEntryBytes + 1));
    check(await cache.get(accountId, urlN(1))).isNotNull();
    check(await cache.get(accountId, urlN(2))).isNull();
  });

  test('entries separate per account', () async {
    await prepare();
    await cache.put(accountId, url, Uint8List.fromList([1]));
    check(await cache.get(otherAccountId, url)).isNull();
  });

  test('remove', () async {
    await prepare();
    await cache.put(accountId, url, Uint8List(10));
    await cache.remove(accountId, url);
    check(await cache.get(accountId, url)).isNull();
  });

  group('removeAccount', () {
    test('delete the account directory', () async {
      await prepare();
      await cache.put(accountId, url, Uint8List(10));
      await cache.put(otherAccountId, url, Uint8List(10));
      await cache.removeAccount(accountId);
      check(filesIn(root)).deepEquals(['$otherAccountId']);
      check(await cache.get(otherAccountId, url)).isNotNull();
    });

    test('no store afterward', () async {
      await prepare();
      await cache.removeAccount(accountId);
      await cache.put(accountId, url, Uint8List(10));
      check(root.existsSync()).isFalse();
    });

    test('no error when nothing cached', () async {
      await prepare();
      await cache.removeAccount(accountId);
    });
  });

  group('retainAccounts', () {
    test('delete directories of other accounts', () async {
      await prepare();
      await cache.put(accountId, url, Uint8List(10));
      await cache.put(otherAccountId, url, Uint8List(10));
      await cache.retainAccounts({otherAccountId, 3});
      check(filesIn(root)).deepEquals(['$otherAccountId']);
      check(await cache.get(otherAccountId, url)).isNotNull();
    });

    test('later calls wait for it', () async {
      await prepare();
      await cache.put(accountId, url, Uint8List(10));
      final future = cache.retainAccounts({});
      check(await cache.get(accountId, url)).isNull();
      await future;
    });

    test('no error when nothing cached', () async {
      await prepare();
      await cache.retainAccounts({accountId});
    });
  });

  test('root directory failure, then retry', () async {
    final tempDir = await Directory.systemTemp.createTemp('image_disk_cache_test');
    addTearDown(() => tempDir.delete(recursive: true));
    var fail = true;
    cache = FileImageDiskCache(getRootDirectory: () async {
      if (fail) throw Exception('no cache directory');
      return tempDir;
    });
    await check(cache.put(accountId, url, Uint8List(10))).throws<Exception>();
    fail = false;
    await cache.put(accountId, url, Uint8List(10));
    check(await cache.get(accountId, url)).isNotNull();
  });

  group('evict', () {
    const entryBytes = 300;
    const maxAccountBytes = 1000;
    late Directory accountDir;

    File fileFor(int n) => accountDir.listSync().whereType<File>()
      .singleWhere((f) => f.readAsBytesSync().first == n);

    /// Store an entry for [urlN] of each of [ns], as in an earlier session,
    /// last used in the order given.
    Future<void> prepareEntries(List<int> ns) async {
      await prepare(maxAccountBytes: maxAccountBytes);
      final earlierCache = FileImageDiskCache(getRootDirectory: () async => root);
      for (final n in ns) {
        await earlierCache.put(accountId, urlN(n), Uint8List(entryBytes)..[0] = n);
      }
      await earlierCache.debugEvictionInProgress(accountId);
      accountDir = Directory(p.join(root.path, '$accountId'));
      final start = DateTime.now().subtract(Duration(days: 1));
      for (final (i, n) in ns.indexed) {
        fileFor(n).setLastModifiedSync(start.add(Duration(hours: i)));
      }
    }

    test('delete least recently used entries', () async {
      await prepareEntries([1, 2, 3, 4]);
      final file1 = fileFor(1);
      final before = file1.lastModifiedSync();
      check(await cache.get(accountId, urlN(1))).isNotNull();
      // The access time is recorded in the background.
      while (file1.lastModifiedSync() == before) {
        await Future<void>.delayed(Duration(milliseconds: 10));
      }

      await cache.evict(accountId);
      check(await cache.get(accountId, urlN(1))).isNotNull();
      check(await cache.get(accountId, urlN(2))).isNull();
      check(await cache.get(accountId, urlN(3))).isNotNull();
      check(await cache.get(accountId, urlN(4))).isNotNull();
    });

    test('no delete when within limit', () async {
      await prepareEntries([1, 2, 3]);
      await cache.evict(accountId);
      check(accountDir.listSync()).length.equals(3);
    });

    test('first put in session evicts', () async {
      await prepareEntries([1, 2, 3, 4]);
      await cache.put(accountId, urlN(5), Uint8List(entryBytes)..[0] = 5);
      final eviction = cache.debugEvictionInProgress(accountId);
      check(eviction).isNotNull();
      await eviction;
      // Down to 90% of the limit.
      check(await cache.get(accountId, urlN(1))).isNull();
      check(await cache.get(accountId, urlN(2))).isNull();
      check(await cache.get(accountId, urlN(3))).isNotNull();
      check(await cache.get(accountId, urlN(4))).isNotNull();
      check(await cache.get(accountId, urlN(5))).isNotNull();
    });

    test('later put evicts only after enough bytes written', () async {
      await prepare(maxAccountBytes: maxAccountBytes);
      await cache.put(accountId, urlN(1), Uint8List(10));
      await cache.debugEvictionInProgress(accountId);

      // The threshold is a tenth of maxAccountBytes.
      await cache.put(accountId, urlN(2), Uint8List(99));
      check(cache.debugEvictionInProgress(accountId)).isNull();
      await cache.put(accountId, urlN(3), Uint8List(1));
      check(cache.debugEvictionInProgress(accountId)).isNotNull();
    });

    test('delete stale temporary files', () async {
      await prepareEntries([1]);
      final now = DateTime.now();
      File(p.join(accountDir.path, 'stale.tmp'))
        ..writeAsBytesSync(Uint8List(10))
        ..setLastModifiedSync(now.subtract(Duration(hours: 2)));
      File(p.join(accountDir.path, 'fresh.tmp'))
        ..writeAsBytesSync(Uint8List(10))
        ..setLastModifiedSync(now.subtract(Duration(minutes: 1)));

      await cache.evict(accountId);
      check(filesIn(accountDir))
        ..length.equals(2)
        ..contains('fresh.tmp')
        ..not((it) => it.contains('stale.tmp'));
    });
  });
}
