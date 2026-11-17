import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zulip/widgets/banner.dart';

import '../model/binding.dart';
import 'test_app.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  group('ZulipBanner', () {
    testWidgets('no actions: padding below label matches padding above', (tester) async {
      addTearDown(testBinding.reset);
      await tester.pumpWidget(TestZulipApp(
        child: Column(children: [
          ZulipBanner(intent: .info, label: 'Some label', actions: []),
        ])));
      await tester.pump();

      final bannerRect = tester.getRect(find.byType(ZulipBanner));
      final labelRect = tester.getRect(find.text('Some label'));
      check(labelRect.top - bannerRect.top).equals(9);
      check(bannerRect.bottom - labelRect.bottom).equals(9);
    });
  });
}
