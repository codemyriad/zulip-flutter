import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../model/avatar_url.dart';
import '../model/binding.dart';
import '../model/image_disk_cache.dart';

/// How a [RealmImageProvider] uses the [ImageDiskCache].
enum ImageDiskCachePolicy {
  /// Use a cached copy if there is one; else fetch, and store the result.
  ///
  /// Appropriate for URLs whose content never changes.
  cacheFirst,

  /// Fetch, and store the result;
  /// use a cached copy only if the fetch fails.
  ///
  /// Appropriate for URLs whose content might change.
  networkFirst,
  ;

  /// The policy to use for [url], an image URL on [realmUrl] or elsewhere.
  ///
  /// Uses [cacheFirst] for on-realm URLs known to point to content
  /// that never changes:
  ///  * URLs with a `version` query parameter,
  ///    which the server bumps when the content changes,
  ///    as on uploaded avatars and the realm icon;
  ///  * `/user_uploads/` URLs, for uploaded files and their thumbnails,
  ///    whose paths include a random component chosen at upload.
  ///
  /// Otherwise uses [networkFirst].
  /// That includes the `/avatar/{user_id}` fallback avatar URL,
  /// realm emoji, and all images from outside the realm.
  /// In particular a Gravatar URL (see [GravatarUrl]) has a `version`,
  /// but the user can change the image on Gravatar
  /// without the server bumping it.
  /// Avatars uploaded to S3-style storage off the realm are also excluded,
  /// because their host can't be told apart from other image hosts.
  static ImageDiskCachePolicy forUrl(Uri url, {required Uri realmUrl}) {
    if (url.origin != realmUrl.origin) return networkFirst;
    if (_hasQueryParameter(url, 'version')) return cacheFirst;
    if (url.path.startsWith('/user_uploads/')) return cacheFirst;
    return networkFirst;
  }

  /// Whether [url]'s query has a parameter named [name].
  ///
  /// Unlike [Uri.queryParameters], this doesn't decode the query,
  /// which would throw on an invalid percent-escape like `%ff`.
  /// A parameter whose name is percent-encoded is not recognized,
  /// which errs toward [networkFirst].
  static bool _hasQueryParameter(Uri url, String name) {
    return url.query.split('&')
      .any((param) => param == name || param.startsWith('$name='));
  }
}

/// Like [NetworkImage], but keeps fetched images in [ZulipBinding.imageDiskCache]
/// so that they can be shown later without a network connection.
///
/// The cache is consulted according to [policy].
/// Any failure of the cache is ignored,
/// so that loading then behaves as if the image were not cached.
///
/// In debug builds, HTTP requests go through
/// [debugNetworkImageHttpClientProvider] if set, as with [NetworkImage].
@immutable
class RealmImageProvider extends ImageProvider<RealmImageProvider> {
  const RealmImageProvider(this.url, {
    required this.accountId,
    required this.headers,
    required this.policy,
    this.scale = 1.0,
  });

  final Uri url;

  /// The account whose cache entries this image uses.
  ///
  /// This also distinguishes images in Flutter's in-memory [ImageCache],
  /// because [headers] may include that account's credentials.
  final int accountId;

  /// HTTP headers to send with the request for [url].
  ///
  /// These are not part of the [ImageCache] key; see [accountId].
  final Map<String, String> headers;

  final ImageDiskCachePolicy policy;

  final double scale;

  @override
  Future<RealmImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<RealmImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(RealmImageProvider key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url.toString(),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<RealmImageProvider>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    RealmImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      assert(key == this);

      if (policy == ImageDiskCachePolicy.cacheFirst) {
        final codec = await _tryDecodeFromCache(decode);
        if (codec != null) return codec;
      }

      final Uint8List bytes;
      try {
        bytes = await _fetch(chunkEvents);
      } catch (e) {
        if (policy == ImageDiskCachePolicy.networkFirst) {
          final codec = await _tryDecodeFromCache(decode);
          if (codec != null) return codec;
        }
        rethrow;
      }

      final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      // Store only what decoded, so the cache holds no non-images.
      unawaited(_tryStore(bytes));
      return codec;
    } catch (e) {
      // As in [NetworkImage]: the image cache may not have had a chance
      // to track the key yet, so give it one before evicting.
      // This way a later attempt to show the image will try again.
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      unawaited(chunkEvents.close());
    }
  }

  ImageDiskCache get _diskCache => ZulipBinding.instance.imageDiskCache;

  /// The image decoded from the disk cache,
  /// or null if not cached or on any failure.
  Future<ui.Codec?> _tryDecodeFromCache(ImageDecoderCallback decode) async {
    final Uint8List? bytes;
    try {
      bytes = await _diskCache.get(accountId, url);
    } catch (e) {
      return null; // TODO(log)
    }
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (e) {
      // The entry is corrupt, perhaps from an interrupted write.
      unawaited(_diskCache.remove(accountId, url).catchError((_) {}));
      return null;
    }
  }

  Future<void> _tryStore(Uint8List bytes) async {
    try {
      await _diskCache.put(accountId, url, bytes);
    } catch (e) {
      // TODO(log)
    }
  }

  // Like [NetworkImage]'s client: with `autoUncompress` false
  // we can trust the `Content-Length` header,
  // and [consolidateHttpClientResponseBytes] does the uncompressing.
  static final HttpClient _sharedHttpClient = HttpClient()..autoUncompress = false;

  static HttpClient get _httpClient {
    HttpClient? client;
    assert(() {
      if (debugNetworkImageHttpClientProvider != null) {
        client = debugNetworkImageHttpClientProvider!();
      }
      return true;
    }());
    return client ?? _sharedHttpClient;
  }

  /// Fetch the image, as [NetworkImage] does.
  Future<Uint8List> _fetch(StreamController<ImageChunkEvent> chunkEvents) async {
    final request = await _httpClient.getUrl(url);
    headers.forEach((name, value) {
      request.headers.add(name, value);
    });
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<List<int>>(<int>[]);
      throw NetworkImageLoadException(statusCode: response.statusCode, uri: url);
    }

    final bytes = await consolidateHttpClientResponseBytes(response,
      onBytesReceived: (cumulative, total) {
        chunkEvents.add(ImageChunkEvent(
          cumulativeBytesLoaded: cumulative, expectedTotalBytes: total));
      });
    if (bytes.lengthInBytes == 0) {
      throw Exception('RealmImageProvider got an empty file: $url');
    }
    return bytes;
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is RealmImageProvider
      && other.url == url
      && other.accountId == accountId
      && other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, accountId, scale);

  @override
  String toString() => '${objectRuntimeType(this, 'RealmImageProvider')}'
    '("$url", accountId: $accountId, scale: ${scale.toStringAsFixed(1)}, '
    'policy: ${policy.name})';
}
