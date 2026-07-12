import 'package:flutter_test/flutter_test.dart';
import 'package:ui_prototype/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const UIPrototypeApp());
    expect(find.byType(UIPrototypeApp), findsOneWidget);
    // SplashScreen schedules a 2s Future.delayed transition; let it fire
    // before the test ends so no timer is left pending.
    await tester.pump(const Duration(seconds: 3));
  });
}