/// Backup numbers as text, the same words in the phone and the PC app.
/// Author: Hao Tran.
library;

import '../backup/backup_status_source.dart';
import 'formatting.dart';

/// One run in a line or two: when, counts, and the problem if any.
String runSummaryText(BackupRunSummary run) {
  final problem = run.problem;
  final isNothingNew =
      run.filesUploaded == 0 &&
      run.filesAlreadyBackedUp == 0 &&
      run.filesFailed == 0 &&
      run.filesLeft == 0 &&
      problem == null;
  if (isNothingNew) {
    return '${formatDateTime(run.finishedAt)}: up to date, nothing new';
  }
  final parts = [
    '${run.filesUploaded} uploaded (${formatBytes(run.bytesUploaded)})',
    '${run.filesAlreadyBackedUp} already there',
    if (run.filesFailed > 0) '${run.filesFailed} failed',
    if (run.filesLeft > 0) '${run.filesLeft} still to do',
  ];
  return '${formatDateTime(run.finishedAt)}: ${parts.join(', ')}'
      '${problem == null ? '' : '\n$problem'}';
}

/// One "verify backup" in a line or two.
String verifySummaryText(VerifySummary verify) {
  final result = verify.filesWrong == 0
      ? 'all ${verify.filesChecked} files OK'
      : '${verify.filesWrong} of ${verify.filesChecked} files wrong or missing';
  final problem = verify.problem;
  return '${formatDateTime(verify.finishedAt)}: $result'
      '${problem == null ? '' : '\n$problem'}';
}

/// How the backup looks at a glance: the colour of the headline.
enum BackupHealth { good, warning, busy }

/// The one line the Backup screen leads with: is everything backed up?
/// Built from the activity and the last run only (no library scan).
({String text, BackupHealth health}) backupHeadline(
  BackupActivity activity,
  BackupRunSummary? lastRun,
) => switch ((activity, lastRun)) {
  (BackupActivity.backingUp, _) => (
    text: 'Backing up…',
    health: BackupHealth.busy,
  ),
  (BackupActivity.verifying, _) => (
    text: 'Checking the backup…',
    health: BackupHealth.busy,
  ),
  (_, null) => (text: 'Not backed up yet', health: BackupHealth.warning),
  (_, final BackupRunSummary run) when run.filesLeft > 0 => (
    text: '${formatCount(run.filesLeft)} files still to back up',
    health: BackupHealth.warning,
  ),
  (_, final BackupRunSummary run)
      when run.problem != null || run.filesFailed > 0 =>
    (text: 'Last backup did not finish', health: BackupHealth.warning),
  _ => (text: 'Backed up', health: BackupHealth.good),
};

/// The lines under the progress bar while a run goes on. A backup says
/// "done" (uploaded or already there), a check says "checked", so the
/// two never read alike.
List<String> liveProgressLines(
  BackupActivity activity,
  BackupLiveProgress? progress,
  DateTime now, {
  String itemsWord = 'files',
}) {
  if (progress == null) return const ['Getting ready…'];
  final checkedText = activity == BackupActivity.verifying
      ? '${formatCount(progress.itemsChecked)} of '
            '${formatCount(progress.itemsTotal)} $itemsWord checked'
      : '${formatCount(progress.itemsChecked)} of '
            '~${formatCount(progress.itemsTotal)} $itemsWord done';
  final speed = progress.bytesPerSecond(now);
  return [
    checkedText,
    '${formatCount(progress.filesUploaded)} uploaded · '
        '${formatBytes(progress.bytesUploaded)}'
        '${speed > 0 ? ' · ${formatBytes(speed.round())}/s' : ''}',
    if (progress.currentPath.isNotEmpty) 'Now: ${progress.currentPath}',
  ];
}
