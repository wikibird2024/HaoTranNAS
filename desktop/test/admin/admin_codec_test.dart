// The admin line protocol parser: every reply form in the server's table
// (server/src/admin.rs) and bad lines, which must not throw.
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_desktop/admin/admin_codec.dart';

T okValue<T>(AdminResult<T> result) => switch (result) {
  AdminOk(:final value) => value,
  AdminFailed(:final message) => fail('expected ok, got: $message'),
};

String failedMessage<T>(AdminResult<T> result) => switch (result) {
  AdminFailed(:final message) => message,
  AdminOk(:final value) => fail('expected a failure, got: $value'),
};

void main() {
  test('status', () {
    expect(okValue(parseStatus(['ok 3 connections'])), 3);
    expect(
      failedMessage(parseStatus(['ok x connections'])),
      contains('Unexpected'),
    );
  });

  test('pair', () {
    final code = okValue(
      parsePair(['code 042317 server-id DEB1-CAE1-944A valid 120 s']),
    );
    expect(code.code, '042317');
    expect(code.serverShortId, 'DEB1-CAE1-944A');
    expect(code.validSeconds, 120);
    expect(
      failedMessage(parsePair(['code 12345 server-id X valid 120 s'])),
      contains('Unexpected'),
      reason: 'five digits',
    );
    expect(
      failedMessage(
        parsePair(['error pairing needs TLS mode (run without --dev-plain)']),
      ),
      'pairing needs TLS mode (run without --dev-plain)',
    );
  });

  test('devices: names with spaces and the word paired, revoked ones', () {
    final devices = okValue(
      parseDevices([
        '1 Android phone paired 1795069400492',
        '2 my paired laptop paired 1795073404549 revoked 1795080000000',
        'ok 2 devices',
      ]),
    );
    expect(devices.map((device) => device.id), [1, 2]);
    expect(devices[0].name, 'Android phone');
    expect(devices[0].isRevoked, isFalse);
    expect(devices[0].pairedAt.millisecondsSinceEpoch, 1795069400492);
    expect(devices[1].name, 'my paired laptop');
    expect(devices[1].revokedAt!.millisecondsSinceEpoch, 1795080000000);
    expect(okValue(parseDevices(['ok 0 devices'])), isEmpty);
  });

  test('devices: count mismatch or a bad line is a failure, not a throw', () {
    expect(
      failedMessage(parseDevices(['1 a paired 5', 'ok 2 devices'])),
      contains('Unexpected'),
    );
    expect(
      failedMessage(parseDevices(['garbage', 'ok 1 devices'])),
      contains('Unexpected'),
    );
    expect(
      failedMessage(parseDevices(['1 a paired 5'])),
      contains('Unexpected'),
    );
    expect(
      failedMessage(parseDevices(['error cannot read the devices: locked'])),
      'cannot read the devices: locked',
    );
  });

  test('revoke', () {
    expect(okValue(parseRevoke(['ok revoked device 4'])), 4);
    expect(failedMessage(parseRevoke(['error no device 9'])), 'no device 9');
  });

  test('scrub and cleanup summaries', () {
    final scrub = okValue(
      parseJobSummary([
        'ok scrub chunks_checked 109 bytes_checked 97524799 bad_found 0 '
            'missing 0 repaired 0 started_at_ms 1795077653674 duration_ms 412',
      ], 'scrub'),
    );
    expect(scrub.chunksChecked, 109);
    expect(scrub.bytesChecked, 97524799);
    expect(scrub.isClean, isTrue);
    expect(scrub.duration, const Duration(milliseconds: 412));
    final bad = okValue(
      parseJobSummary([
        'ok scrub chunks_checked 9 bad_found 2 missing 1',
      ], 'scrub'),
    );
    expect(bad.isClean, isFalse);
    expect(bad.repaired, 0, reason: 'a missing name reads as 0');

    final cleanup = okValue(
      parseJobSummary([
        'ok cleanup expired_uploads 1 tmp_files 2 unused_chunks 3 '
            'orphan_files 4 orphan_pass yes duration_ms 5',
      ], 'cleanup'),
    );
    expect(
      [
        cleanup.expiredUploads,
        cleanup.tmpFiles,
        cleanup.unusedChunks,
        cleanup.orphanFiles,
      ],
      [1, 2, 3, 4],
    );
    expect(
      failedMessage(parseJobSummary(['ok cleanup a 1'], 'scrub')),
      contains('Unexpected'),
    );
    expect(
      failedMessage(parseJobSummary(['ok scrub odd'], 'scrub')),
      contains('Unexpected'),
    );
    expect(
      failedMessage(
        parseJobSummary([
          'error no scrub has finished yet (run scrub-now)',
        ], 'scrub'),
      ),
      'no scrub has finished yet (run scrub-now)',
    );
  });

  test('empty reply and progress lines', () {
    expect(failedMessage(parseStatus(const [])), contains('without a reply'));
    expect(parseProgress('progress 256'), 256);
    expect(parseProgress('progress x'), isNull);
    expect(parseProgress('ok scrub'), isNull);
  });

  test('command lines', () {
    expect(AdminCommand.revoke(7), 'revoke 7');
    expect(AdminCommand.scrubNow, 'scrub-now');
  });
}
