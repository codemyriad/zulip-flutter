import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:flutter_checks/flutter_checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/avatar_url.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/widgets/icons.dart';
import 'package:zulip/widgets/image.dart';
import 'package:zulip/widgets/user.dart';

import '../example_data.dart' as eg;
import '../model/binding.dart';
import '../model/test_store.dart';
import '../stdlib_checks.dart';
import '../test_images.dart';
import 'test_app.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  group('AvatarImage', () {
    late PerAccountStore store;
    late User user;

    final findPlaceholder = find.descendant(
      of: find.byType(AvatarImage),
      matching: find.byIcon(ZulipIcons.person),
    );

    Future<Uri?> actualUrl(WidgetTester tester, String? avatarUrl, [double? size]) async {
      addTearDown(testBinding.reset);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      user = eg.user(avatarUrl: avatarUrl);
      await store.addUser(user);

      prepareBoringImageHttpClient();
      await tester.pumpWidget(
        TestZulipApp(accountId: eg.selfAccount.id,
          child: AvatarImage(userId: user.userId, size: size ?? 30)));
      await tester.pump();
      await tester.pump();
      tester.widget(find.byType(AvatarImage));
      final widgets = tester.widgetList<RealmContentNetworkImage>(
        find.byType(RealmContentNetworkImage));
      return widgets.firstOrNull?.src;
    }

    testWidgets('smoke with absolute URL', (tester) async {
      const avatarUrl = 'https://example/avatar.png';
      check(await actualUrl(tester, avatarUrl)).isNotNull()
        .asString.equals(avatarUrl);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('smoke with relative URL', (tester) async {
      const avatarUrl = '/avatar.png';
      check(await actualUrl(tester, avatarUrl))
        .equals(store.tryResolveUrl(avatarUrl)!);
      debugNetworkImageHttpClientProvider = null;
    });

   testWidgets('absolute URL, larger size', (tester) async {
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.resetDevicePixelRatio);

      const avatarUrl = 'https://example/avatar.png';
      check(await actualUrl(tester, avatarUrl, 50)).isNotNull()
        .asString.equals(avatarUrl.replaceAll('.png', '-medium.png'));
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('relative URL, larger size', (tester) async {
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.resetDevicePixelRatio);

      const avatarUrl = '/avatar.png';
      check(await actualUrl(tester, avatarUrl, 50))
        .equals(store.tryResolveUrl('/avatar-medium.png')!);
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('smoke with invalid URL', (tester) async {
      const avatarUrl = '::not a URL::';
      check(await actualUrl(tester, avatarUrl)).isNull();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('shows placeholder when user is not found', (tester) async {
      addTearDown(testBinding.reset);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);

      const nonExistentUserId = 9999999;
      check(store.getUser(nonExistentUserId)).isNull();

      await tester.pumpWidget(
        TestZulipApp(accountId: eg.selfAccount.id,
          child: AvatarImage(userId: nonExistentUserId, size: 30)));
      await tester.pump();
      check(findPlaceholder).findsOne();
    });

    testWidgets('fallback URL when avatarUrl is missing', (tester) async {
      check(await actualUrl(tester, null))
        .equals(store.realmUrl.resolve('/avatar/${user.userId}'));
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('fallback URL when avatarUrl is missing, larger size', (tester) async {
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.resetDevicePixelRatio);

      check(await actualUrl(tester, null, 50))
        .equals(store.realmUrl.resolve('/avatar/${user.userId}/medium'));
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('shows placeholder when image fails to load', (tester) async {
      final httpClient = FakeImageHttpClient();
      debugNetworkImageHttpClientProvider = () => httpClient;
      httpClient.request.response
        ..statusCode = HttpStatus.notFound
        ..content = <int>[];

      addTearDown(testBinding.reset);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);

      final badUser = eg.user(avatarUrl: 'https://zulip.com/avatarinvalid.png');
      await store.addUser(badUser);

      await tester.pumpWidget(
        TestZulipApp(accountId: eg.selfAccount.id,
          child: AvatarImage(userId: badUser.userId, size: 30)));
      await tester.pump();
      await tester.pump();
      check(findPlaceholder).findsOne();

      debugNetworkImageHttpClientProvider = null;
    });

  });

  group('AvatarImage disk cache', () {
    late FakeImageHttpClient httpClient;
    late Uri shownUrl;

    // As in the server's file name for an uploaded avatar.
    const avatarHash = 'ff062b0fee41738b38c4312bb33bdf3fe2aad463';

    /// Show the avatar for [avatarUrl], with its image already on disk.
    Future<void> prepare(WidgetTester tester, String avatarUrl, {
      double size = 30,
    }) async {
      addTearDown(testBinding.reset);
      addTearDown(imageCache.clear);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      final user = eg.user(avatarUrl: avatarUrl);
      await store.addUser(user);

      shownUrl = AvatarUrl.fromUserData(resolvedUrl: store.realmUrl.resolve(avatarUrl),
        userId: user.userId, realmUrl: store.realmUrl,
      ).get((tester.view.devicePixelRatio * size).ceil());
      await testBinding.imageDiskCache.put(eg.selfAccount.id, shownUrl,
        Uint8List.fromList(kSolidBlueAvatar));

      httpClient = prepareBoringImageHttpClient();
      await tester.pumpWidget(TestZulipApp(accountId: eg.selfAccount.id,
        child: AvatarImage(userId: user.userId, size: size)));
      await tester.pump(); // Load the store.
      // Let the image load, from the cache or network, and decode;
      // decoding happens outside the test's fake async.
      for (int i = 0; i < 50; i++) {
        final rawImages = tester.widgetList<RawImage>(find.byType(RawImage));
        if (rawImages.any((w) => w.image != null)) break;
        await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: 10)));
        await tester.pump();
      }
      check(tester.widget<RawImage>(find.byType(RawImage)).image).isNotNull();
    }

    testWidgets('uploaded avatar on realm: no request', (tester) async {
      await prepare(tester, '/user_avatars/2/$avatarHash.png');
      check(shownUrl.path).endsWith('/$avatarHash.png');
      check(httpClient.requestedUrls).isEmpty();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('uploaded avatar on realm, medium: no request', (tester) async {
      await prepare(tester, '/user_avatars/2/$avatarHash.png', size: 100);
      check(shownUrl.path).endsWith('/$avatarHash-medium.png');
      check(httpClient.requestedUrls).isEmpty();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('uploaded avatar off realm: no request', (tester) async {
      // As when the server keeps avatars in S3-style storage.
      await prepare(tester, 'https://uploads.example/2/$avatarHash.png');
      check(shownUrl.path).endsWith('/$avatarHash.png');
      check(httpClient.requestedUrls).isEmpty();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('uploaded avatar off realm, medium: no request', (tester) async {
      await prepare(tester, 'https://uploads.example/2/$avatarHash.png', size: 100);
      check(shownUrl.path).endsWith('/$avatarHash-medium.png');
      check(httpClient.requestedUrls).isEmpty();
      debugNetworkImageHttpClientProvider = null;
    });

    testWidgets('Gravatar: fetch', (tester) async {
      await prepare(tester,
        'https://secure.gravatar.com/avatar/abc?d=identicon&version=3');
      check(httpClient.requestedUrls).single.equals(shownUrl);
      debugNetworkImageHttpClientProvider = null;
    });
  });
}
