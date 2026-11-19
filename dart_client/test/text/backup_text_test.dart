// The shared backup texts (phone and PC).
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/text/backup_text.dart';

BackupRunSummary run({
  int uploaded = 0,
  int alreadyThere = 0,
  int failed = 0,
  int bytes = 0,
  String? problem,
}) => BackupRunSummary(
  finishedAt: DateTime(2026, 11, 19, 17, 15),
  filesUploaded: uploaded,
  filesAlreadyBackedUp: alreadyThere,
  filesFailed: failed,
  bytesUploaded: bytes,
  problem: problem,
);

void main() {
  test('a run with nothing new says so', () {
    expect(runSummaryText(run()), '2026-11-19 17:15: up to date, nothing new');
  });

  test('counts, failures and the problem', () {
    expect(
      runSummaryText(run(uploaded: 2, alreadyThere: 1, failed: 1, bytes: 2048)),
      '2026-11-19 17:15: 2 uploaded (2.0 KB), 1 already there, 1 failed',
    );
    expect(
      runSummaryText(run(problem: 'No address worked')),
      '2026-11-19 17:15: 0 uploaded (0 B), 0 already there\nNo address worked',
    );
  });
}
