// The shared backup texts (phone and PC).
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/text/backup_text.dart';

BackupRunSummary run({
  int uploaded = 0,
  int alreadyThere = 0,
  int failed = 0,
  int bytes = 0,
  int left = 0,
  String? problem,
}) => BackupRunSummary(
  finishedAt: DateTime(2026, 11, 19, 17, 15),
  filesUploaded: uploaded,
  filesAlreadyBackedUp: alreadyThere,
  filesFailed: failed,
  bytesUploaded: bytes,
  filesLeft: left,
  problem: problem,
);

void main() {
  test('a run with nothing new says so', () {
    expect(runSummaryText(run()), '2026-11-19 17:15: up to date, nothing new');
  });

  test('headline: busy, never, did not finish, backed up', () {
    String headline(BackupActivity activity, BackupRunSummary? lastRun) =>
        backupHeadline(activity, lastRun).text;
    expect(headline(BackupActivity.backingUp, run()), 'Backing up…');
    expect(headline(BackupActivity.verifying, null), 'Checking the backup…');
    expect(headline(BackupActivity.idle, null), 'Not backed up yet');
    expect(
      headline(BackupActivity.idle, run(failed: 1)),
      'Last backup did not finish',
    );
    expect(
      headline(BackupActivity.idle, run(problem: 'No Wi-Fi')),
      'Last backup did not finish',
    );
    expect(headline(BackupActivity.idle, run(uploaded: 3)), 'Backed up');
    expect(
      headline(BackupActivity.idle, run(left: 1240, problem: 'Time is up')),
      '1 240 files still to back up',
    );
    expect(
      backupHeadline(BackupActivity.idle, run()).health,
      BackupHealth.good,
    );
  });

  test('a backup says "done", a check says "checked"', () {
    final progress = BackupLiveProgress(
      startedAt: DateTime(2026),
      itemsChecked: 5,
      itemsTotal: 1240,
      filesUploaded: 0,
      bytesUploaded: 0,
      currentPath: '',
    );
    final now = DateTime(2026);
    expect(
      liveProgressLines(BackupActivity.backingUp, progress, now).first,
      '5 of ~1 240 files done',
    );
    expect(
      liveProgressLines(BackupActivity.verifying, progress, now).first,
      '5 of 1 240 files checked',
    );
  });

  test('counts, failures and the problem', () {
    expect(
      runSummaryText(run(uploaded: 2, alreadyThere: 1, failed: 1, bytes: 2048)),
      '2026-11-19 17:15: 2 uploaded (2.0 KB), 1 already there, 1 failed',
    );
    expect(
      runSummaryText(run(uploaded: 1, left: 37)),
      '2026-11-19 17:15: 1 uploaded (0 B), 0 already there, 37 still to do',
    );
    expect(
      runSummaryText(run(problem: 'No address worked')),
      '2026-11-19 17:15: 0 uploaded (0 B), 0 already there\nNo address worked',
    );
  });
}
