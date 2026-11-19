// iPhone photo folder on the NAS (D-043). Author: Hao Tran.
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/backup/photo_media_source.dart';

void main() {
  test('iPhone photos go to iPhone/<yyyy>-<mm> in UTC', () {
    // 2026-11-20 14:05 UTC.
    expect(iPhoneMediaFolder(1795183500), 'iPhone/2026-11');
    // 2026-01-01 00:30 UTC: still January, whatever the phone's zone.
    expect(iPhoneMediaFolder(1767227400), 'iPhone/2026-01');
    expect(iPhoneMediaFolder(0), 'iPhone/1970-01');
  });
}
