import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/main.dart';

void main() {
  testWidgets('app starts and shows its name', (tester) async {
    await tester.pumpWidget(const HaoTranNasApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'HaoTranNAS');
    expect(find.text('HaoTranNAS'), findsOneWidget);
  });
}
