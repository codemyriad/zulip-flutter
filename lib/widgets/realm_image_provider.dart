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
  /// Uses [cacheFirst] for URLs known to point to content
  /// that never changes:
  ///  * any URL, if [contentImmutable] is true;
  ///  * URLs with a `version` query parameter,
  ///    if on the realm or if [versionTracksContent] is true;
  ///  * on-realm `/user_uploads/` URLs, for uploaded files and their thumbnails,
  ///    whose paths include a random component chosen at upload.
  ///
  /// Otherwise uses [networkFirst].
  /// That includes the `/avatar/{user_id}` fallback avatar URL,
  /// realm emoji, and by default all images from outside the realm.
  ///
  /// Pass true for [contentImmutable] when [url] came from the server
  /// as an image whose URL the server changes whenever the image changes,
  /// wherever the image is hosted:
  /// an avatar the server stores (see [UploadedAvatarUrl.contentImmutable]).
  /// The server may keep those in S3-style storage, off the realm.
  ///
  /// Pass true for [versionTracksContent] when [url] came from the server
  /// as an image whose `version` query parameter, if any,
  /// the server bumps whenever the image changes,
  /// wherever the image is hosted:
  /// the realm icon, or an avatar URL other than Gravatar's
  /// (see [UploadedAvatarUrl.versionTracksContent]).
  /// Don't pass true for a Gravatar URL (see [GravatarUrl]):
  /// it has a `version`, but the user can change the image on Gravatar
  /// without the server bumping it.
  /// The parameter has no effect on a URL without a `version`.
  ///
  /// Off-realm URLs are network-first by default
  /// because a `version` there need not say anything about the content,
  /// as on Gravatar URLs, or on an external image linked from a message.
  static ImageDiskCachePolicy forUrl(Uri url, {
    required Uri realmUrl,
    bool contentImmutable = false,
    bool versionTracksContent = false,
  }) {
    if (contentImmutable) return cacheFirst;
    final hasVersion = _hasQueryParameter(url, 'version');
    if (versionTracksContent && hasVersion) return cacheFirst;
    if (url.origin != realmUrl.origin) return networkFirst;
    if (hasVersion) return cacheFirst;
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

  /// How this image uses the disk cache.
  ///
  /// This is not part of the [ImageCache] key:
  /// two providers for the same URL and account share an in-memory image
  /// even if their policies differ.
  /// That's harmless because a policy only affects
  /// whether a stored copy of the same URL may be shown,
  /// and [ImageDiskCachePolicy.cacheFirst] is chosen only for a URL
  /// whose content never changes, wherever it is shown.
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
      final ui.Codec codec;
      try {
        bytes = await _fetch(chunkEvents);
        // A response that doesn't decode, like a captive portal's login page,
        // is a failure to get the image like any other.
        codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      } catch (e) {
        if (policy == ImageDiskCachePolicy.networkFirst) {
          final cached = await _tryDecodeFromCache(decode);
          if (cached != null) return cached;
        }
        rethrow;
      }

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
