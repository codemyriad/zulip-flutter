import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'binding.dart';

/// Persistent storage for image bytes fetched from the network,
/// keyed by account and URL.
///
/// This lets images that were shown once be shown again
/// without a network connection, including after the app restarts.
///
/// Callers should treat every method as fallible
/// and fall back to the network on any error.
///
/// See [ZulipBinding.imageDiskCache].
abstract class ImageDiskCache {
  /// The bytes stored for [url] under [accountId], or null if none.
  Future<Uint8List?> get(int accountId, Uri url);

  /// Store [bytes] for [url] under [accountId], replacing any previous entry.
  ///
  /// The implementation may decline to store the entry,
  /// for example because it is too large.
  Future<void> put(int accountId, Uri url, Uint8List bytes);

  /// Remove the entry for [url] under [accountId], if any.
  Future<void> remove(int accountId, Uri url);

  /// Remove all entries for [accountId],
  /// and decline to store new ones for it.
  ///
  /// Called when the account is removed (for example by logging out).
  /// Account IDs are never reused (see `Accounts.id` in the database),
  /// so this need not be undone.
  Future<void> removeAccount(int accountId);
}

/// An [ImageDiskCache] storing one file per entry,
/// in a directory per account under [getRootDirectory].
///
/// Entries larger than [maxEntryBytes] are not stored.
/// When an account's entries exceed [maxAccountBytes] in total,
/// the least recently used are evicted,
/// in the background after a [put].
/// Use is tracked by the files' modification times.
class FileImageDiskCache implements ImageDiskCache {
  FileImageDiskCache({
    required this.getRootDirectory,
    this.maxEntryBytes = 2 * 1024 * 1024,
    this.maxAccountBytes = 100 * 1024 * 1024,
  });

  /// The directory holding the cache, typically in the platform's cache area.
  ///
  /// It is called on first use; if it throws, it is called again on next use.
  final Future<Directory> Function() getRootDirectory;

  final int maxEntryBytes;
  final int maxAccountBytes;

  /// How many bytes can be written for an account
  /// before another eviction pass is run on it.
  int get _bytesBetweenEvictions => maxAccountBytes ~/ 10;

  Future<Directory>? _rootDirectory;

  Future<Directory> _accountDirectory(int accountId) async {
    final future = _rootDirectory ??= getRootDirectory();
    final Directory root;
    try {
      root = await future;
    } catch (e) {
      if (identical(_rootDirectory, future)) _rootDirectory = null;
      rethrow;
    }
    return Directory(p.join(root.path, accountId.toString()));
  }

  static String _fileName(Uri url) {
    return sha256.convert(utf8.encode(url.toString())).toString();
  }

  static const _tempSuffix = '.tmp';

  Future<File> _file(int accountId, Uri url) async {
    final dir = await _accountDirectory(accountId);
    return File(p.join(dir.path, _fileName(url)));
  }

  final Set<int> _removedAccounts = {};

  @override
  Future<Uint8List?> get(int accountId, Uri url) async {
    if (_removedAccounts.contains(accountId)) return null;
    final file = await _file(accountId, url);
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
    // Mark the entry as recently used, for eviction.
    unawaited(file.setLastModified(ZulipBinding.instance.utcNow())
      .catchError((_) {}));
    return bytes;
  }

  @override
  Future<void> put(int accountId, Uri url, Uint8List bytes) async {
    if (bytes.length > maxEntryBytes) return;
    if (_removedAccounts.contains(accountId)) return;
    final file = await _file(accountId, url);
    await file.parent.create(recursive: true);

    // Write to a temporary file and rename it into place,
    // so a reader never sees a partially-written entry.
    final suffix = Random().nextInt(1 << 32).toRadixString(16);
    final temp = File('${file.path}.$suffix$_tempSuffix');
    try {
      await temp.writeAsBytes(bytes);
      await temp.rename(file.path);
    } catch (e) {
      unawaited(temp.delete().then((_) {}, onError: (_) {}));
      rethrow;
    }

    final written = (_bytesWrittenSinceEviction[accountId] ?? 0) + bytes.length;
    _bytesWrittenSinceEviction[accountId] = written;
    if (!_evictedAccounts.contains(accountId)
        || written >= _bytesBetweenEvictions) {
      unawaited(evict(accountId).catchError((_) {}));
    }
  }

  @override
  Future<void> remove(int accountId, Uri url) async {
    final file = await _file(accountId, url);
    try {
      await file.delete();
    } on PathNotFoundException {
      // Already absent.
    }
  }

  @override
  Future<void> removeAccount(int accountId) async {
    _removedAccounts.add(accountId);
    final dir = await _accountDirectory(accountId);
    try {
      await dir.delete(recursive: true);
    } on PathNotFoundException {
      // Nothing was cached for this account.
    }
  }

  /// The accounts for which an eviction pass has started in this session.
  final Set<int> _evictedAccounts = {};

  final Map<int, int> _bytesWrittenSinceEviction = {};

  final Map<int, Future<void>> _evictions = {};

  /// The eviction pass in progress for [accountId], if any.
  @visibleForTesting
  Future<void>? debugEvictionInProgress(int accountId) => _evictions[accountId];

  /// Delete the least recently used entries for [accountId]
  /// until they fit within [maxAccountBytes],
  /// and delete stale temporary files.
  ///
  /// This is called automatically after [put] from time to time,
  /// so callers need not call it.
  /// If a pass is already in progress for the account,
  /// returns its future instead of starting another.
  Future<void> evict(int accountId) {
    final inProgress = _evictions[accountId];
    if (inProgress != null) return inProgress;
    _evictedAccounts.add(accountId);
    _bytesWrittenSinceEviction[accountId] = 0;
    final future = _evict(accountId).whenComplete(() {
      _evictions.remove(accountId);
    });
    _evictions[accountId] = future;
    return future;
  }

  /// Once evicting, how far below [maxAccountBytes] to go,
  /// so that eviction need not run again right away.
  static const _evictionTargetRatio = 0.9;

  /// How old a temporary file must be to be deleted,
  /// as presumably left behind by an interrupted [put].
  static const _staleTempFileAge = Duration(hours: 1);

  Future<void> _evict(int accountId) async {
    final dir = await _accountDirectory(accountId);
    final now = ZulipBinding.instance.utcNow();
    final entries = <({File file, int size, DateTime modified})>[];
    var totalBytes = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final FileStat stat;
        try {
          stat = await entity.stat();
        } on FileSystemException {
          continue; // Perhaps deleted concurrently.
        }
        if (entity.path.endsWith(_tempSuffix)) {
          if (now.difference(stat.modified) > _staleTempFileAge) {
            await _tryDelete(entity);
          }
          continue;
        }
        entries.add((file: entity, size: stat.size, modified: stat.modified));
        totalBytes += stat.size;
      }
    } on PathNotFoundException {
      return; // Nothing cached for this account.
    }

    if (totalBytes <= maxAccountBytes) return;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    final targetBytes = maxAccountBytes * _evictionTargetRatio;
    for (final entry in entries) {
      if (totalBytes <= targetBytes) break;
      await _tryDelete(entry.file);
      totalBytes -= entry.size;
    }
  }

  static Future<void> _tryDelete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Perhaps deleted concurrently.
    }
  }
}
