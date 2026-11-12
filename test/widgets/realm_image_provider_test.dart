import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_checks/flutter_checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zulip/widgets/image.dart';
import 'package:zulip/widgets/realm_image_provider.dart';
import 'package:zulip/widgets/store.dart';

import '../example_data.dart' as eg;
import '../model/binding.dart';
import '../test_images.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  group('ImageDiskCachePolicy.forUrl', () {
    final realmUrl = Uri.parse('https://chat.example/');

    void checkPolicy(String url, ImageDiskCachePolicy expected) {
      check(ImageDiskCachePolicy.forUrl(Uri.parse(url), realmUrl: realmUrl))
        .equals(expected);
    }

    test('cache-first for versioned URLs', () {
      checkPolicy('https://chat.example/user_avatars/2/abc.png?version=3',
        ImageDiskCachePolicy.cacheFirst);
      checkPolicy('https://secure.gravatar.com/avatar/abc?d=identicon&version=1',
        ImageDiskCachePolicy.cacheFirst);
      checkPolicy('https://chat.example/user_avatars/2/realm/icon.png?version=2',
        ImageDiskCachePolicy.cacheFirst);
    });

    test('cache-first for on-realm uploads and thumbnails', () {
      checkPolicy('https://chat.example/user_uploads/2/ab/xyz/image.png',
        ImageDiskCachePolicy.cacheFirst);
      checkPolicy('https://chat.example/user_uploads/thumbnail/2/ab/xyz/image.png/840x560.webp',
        ImageDiskCachePolicy.cacheFirst);
    });

    test('network-first otherwise', () {
      checkPolicy('https://chat.example/avatar/123',
        ImageDiskCachePolicy.networkFirst);
      checkPolicy('https://chat.example/user_avatars/2/emoji/images/1.png',
        ImageDiskCachePolicy.networkFirst);
      checkPolicy('https://chat.example/external_content/abc/def',
        ImageDiskCachePolicy.networkFirst);
      checkPolicy('https://other.example/user_uploads/2/ab/xyz/image.png',
        ImageDiskCachePolicy.networkFirst);
      checkPolicy('https://chat.example/static/image.png?versions=1',
        ImageDiskCachePolicy.networkFirst);
    });

    test('network-first for query with invalid percent-escape', () {
      checkPolicy('https://chat.example/static/image.png?a=%ff',
        ImageDiskCachePolicy.networkFirst);
    });
  });

  group('RealmImageProvider', () {
    final cacheFirstUrl = Uri.parse('https://chat.example/user_uploads/2/ab/xyz/image.png');
    final networkFirstUrl = Uri.parse('https://chat.example/avatar/123');
    final imageBytes = Uint8List.fromList(kSolidBlueAvatar);

    late FakeImageHttpClient httpClient;

    final findError = find.text('error');

    void prepareImageHttpClient({int statusCode = HttpStatus.ok, List<int>? content}) {
      httpClient = prepareBoringImageHttpClient();
      httpClient.request.response
        ..statusCode = statusCode
        ..content = content ?? kSolidBlueAvatar;
    }

    Future<void> pumpImage(WidgetTester tester, Uri url) async {
      await tester.pumpWidget(GlobalStoreWidget(
        child: PerAccountStoreWidget(accountId: eg.selfAccount.id,
          child: RealmContentNetworkImage(url,
            errorBuilder: (_, _, _) => const Text('error',
              textDirection: TextDirection.ltr)))));
      await tester.pump(); // Load the store.
      // Let the image load, from the cache or network, and decode;
      // decoding happens outside the test's fake async.
      for (int i = 0; i < 50; i++) {
        if (findError.evaluate().isNotEmpty) break;
        final rawImages = tester.widgetList<RawImage>(find.byType(RawImage));
        if (rawImages.any((w) => w.image != null)) break;
        await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    Future<void> prepare() async {
      addTearDown(testBinding.reset);
      addTearDown(imageCache.clear);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
    }

    void checkImageShown(WidgetTester tester) {
      check(findError).findsNothing();
      check(tester.widget<RawImage>(find.byType(RawImage)).image).isNotNull();
    }

    Map<Uri, Uint8List>? cachedEntries() =>
      testBinding.imageDiskCache.entries[eg.selfAccount.id];

    Future<void> putCached(Uri url, Uint8List bytes, [int? accountId]) =>
      testBinding.imageDiskCache.put(accountId ?? eg.selfAccount.id, url, bytes);

    testWidgets('cache miss: fetch and store', (tester) async {
      await prepare();
      prepareImageHttpClient();
      await pumpImage(tester, cacheFirstUrl);
      check(httpClient.requestedUrls).single.equals(cacheFirstUrl);
      checkImageShown(tester);
      check(cachedEntries()).isNotNull()[cacheFirstUrl].isNotNull()
        .deepEquals(imageBytes);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('cache-first, cache hit: no request', (tester) async {
      await prepare();
      prepareImageHttpClient();
      await putCached(cacheFirstUrl, imageBytes);
      await pumpImage(tester, cacheFirstUrl);
      check(httpClient.requestedUrls).isEmpty();
      checkImageShown(tester);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('cache-first, corrupt entry: fetch and replace', (tester) async {
      await prepare();
      prepareImageHttpClient();
      await putCached(cacheFirstUrl, Uint8List.fromList([1, 2, 3]));
      await pumpImage(tester, cacheFirstUrl);
      check(httpClient.requestedUrls).single.equals(cacheFirstUrl);
      checkImageShown(tester);
      check(cachedEntries()![cacheFirstUrl]).isNotNull().deepEquals(imageBytes);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('network-first, cache hit: fetch and store', (tester) async {
      await prepare();
      prepareImageHttpClient();
      await putCached(networkFirstUrl, Uint8List.fromList([1, 2, 3]));
      await pumpImage(tester, networkFirstUrl);
      check(httpClient.requestedUrls).single.equals(networkFirstUrl);
      checkImageShown(tester);
      check(cachedEntries()![networkFirstUrl]).isNotNull().deepEquals(imageBytes);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('network-first, fetch fails: show cached', (tester) async {
      await prepare();
      prepareImageHttpClient();
      httpClient.exception = SocketException('offline');
      await putCached(networkFirstUrl, imageBytes);
      await pumpImage(tester, networkFirstUrl);
      check(httpClient.requestedUrls).single.equals(networkFirstUrl);
      checkImageShown(tester);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('network-first, HTTP error: show cached', (tester) async {
      await prepare();
      prepareImageHttpClient(statusCode: HttpStatus.serviceUnavailable, content: []);
      await putCached(networkFirstUrl, imageBytes);
      await pumpImage(tester, networkFirstUrl);
      checkImageShown(tester);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('fetch fails, not cached: show error', (tester) async {
      await prepare();
      prepareImageHttpClient();
      httpClient.exception = SocketException('offline');
      await pumpImage(tester, networkFirstUrl);
      check(findError).findsOne();
      check(cachedEntries()).isNull();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('response not an image: show error, no store', (tester) async {
      await prepare();
      prepareImageHttpClient(content: [1, 2, 3]);
      await pumpImage(tester, cacheFirstUrl);
      check(findError).findsOne();
      check(cachedEntries()).isNull();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('cache fails: fetch and show', (tester) async {
      await prepare();
      prepareImageHttpClient();
      testBinding.imageDiskCache.exception = FileSystemException('disk full');
      await pumpImage(tester, cacheFirstUrl);
      check(httpClient.requestedUrls).single.equals(cacheFirstUrl);
      checkImageShown(tester);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('cache fails, fetch fails: show error', (tester) async {
      await prepare();
      prepareImageHttpClient();
      httpClient.exception = SocketException('offline');
      testBinding.imageDiskCache.exception = FileSystemException('disk broken');
      await pumpImage(tester, networkFirstUrl);
      check(findError).findsOne();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('entries separate per account', (tester) async {
      await prepare();
      await testBinding.globalStore.add(eg.otherAccount, eg.initialSnapshot());
      prepareImageHttpClient();
      await putCached(cacheFirstUrl, imageBytes, eg.otherAccount.id);
      await pumpImage(tester, cacheFirstUrl);
      check(httpClient.requestedUrls).single.equals(cacheFirstUrl);
      check(cachedEntries()![cacheFirstUrl]).isNotNull();
      debugNetworkImageHttpClientProvider = null;
    });
  });
}
