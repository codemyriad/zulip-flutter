import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/model/avatar_url.dart';

void main() {
  const defaultSize = 30;
  const largeSize = 120;

  const userId = 123;
  final realmUrl = Uri.parse('https://zulip.example/');

  // As in the server's file name for an uploaded avatar.
  const avatarHash = 'ff062b0fee41738b38c4312bb33bdf3fe2aad463';

  AvatarUrl fromUserData(Uri? resolvedUrl) => AvatarUrl.fromUserData(
    resolvedUrl: resolvedUrl, userId: userId, realmUrl: realmUrl);

  group('GravatarUrl', () {
    test('gravatar url', () {
      final url = '${GravatarUrl.origin}/avatar/1234';
      final avatarUrl = fromUserData(Uri.parse(url));

      check(avatarUrl.get(defaultSize).toString()).equals('$url?s=30');
    });

    test('version does not track content', () {
      final avatarUrl = fromUserData(Uri.parse(
        '${GravatarUrl.origin}/avatar/1234?d=identicon&version=1'));
      check(avatarUrl).isA<GravatarUrl>();
      check(avatarUrl.versionTracksContent).isFalse();
      check(avatarUrl.contentImmutable).isFalse();
    });

    test('isGravatarUrl', () {
      check(GravatarUrl.isGravatarUrl(Uri.parse(
        'https://secure.gravatar.com/avatar/1234?d=identicon&version=1'))).isTrue();
      check(GravatarUrl.isGravatarUrl(Uri.parse(
        'https://zulip.example/user_avatars/2/realm/icon.png?version=2'))).isFalse();
    });
  });

  group('FallbackAvatarUrl', () {
    test('standard size', () {
      final avatarUrl = fromUserData(null);

      check(avatarUrl.get(defaultSize).toString())
        .equals('https://zulip.example/avatar/$userId');
    });

    test('larger size', () {
      final avatarUrl = fromUserData(null);

      check(avatarUrl.get(largeSize).toString())
        .equals('https://zulip.example/avatar/$userId/medium');
    });

    test('version does not track content', () {
      final avatarUrl = fromUserData(null);
      check(avatarUrl).isA<FallbackAvatarUrl>();
      check(avatarUrl.versionTracksContent).isFalse();
      check(avatarUrl.contentImmutable).isFalse();
    });
  });

  group('UploadedAvatarUrl', () {
    test('png image', () {
      const url = 'https://zulip.example/image.png';
      final avatarUrl = fromUserData(Uri.parse(url));

      check(avatarUrl.get(defaultSize).toString()).equals(url);
    });

    test('png image, larger size', () {
      const url = 'https://zulip.example/image.png';
      final avatarUrl = fromUserData(Uri.parse(url));
      final expectedUrl = url.replaceAll('.png', '-medium.png');

      check(avatarUrl.get(largeSize).toString()).equals(expectedUrl);
    });

    test('version tracks content, also off-realm', () {
      // As for the server's default avatar, at a configured URL,
      // on a server not using Gravatar.
      final avatarUrl = fromUserData(Uri.parse(
        'https://cdn.example/default-avatar.png?version=3'));
      check(avatarUrl).isA<UploadedAvatarUrl>();
      check(avatarUrl.versionTracksContent).isTrue();
      check(avatarUrl.contentImmutable).isFalse();
    });

    group('contentImmutable', () {
      void checkImmutable(String url) {
        final avatarUrl = fromUserData(Uri.parse(url));
        check(avatarUrl).isA<UploadedAvatarUrl>();
        check(avatarUrl.contentImmutable).isTrue();
        check(avatarUrl.get(defaultSize).path).endsWith('/$avatarHash.png');
        check(avatarUrl.get(largeSize).path).endsWith('/$avatarHash-medium.png');
      }

      test('uploaded avatar on realm', () {
        checkImmutable('https://zulip.example/user_avatars/2/$avatarHash.png');
      });

      test('uploaded avatar off realm', () {
        // As in S3-style storage.
        checkImmutable('https://uploads.example/2/$avatarHash.png');
      });

      test('false for other file names', () {
        for (final url in [
          'https://zulip.example/static/images/default-avatar.png?version=3',
          'https://zulip.example/static/images/static_avatars/welcome-bot.png',
          'https://uploads.example/2/${avatarHash.substring(1)}.png',
          'https://uploads.example/2/${avatarHash.toUpperCase()}.png',
          'https://uploads.example/2/$avatarHash',
        ]) {
          check(because: url, fromUserData(Uri.parse(url)).contentImmutable)
            .isFalse();
        }
      });
    });
  });
}
