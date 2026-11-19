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
      problem == null;
  if (isNothingNew) {
    return '${formatDateTime(run.finishedAt)}: up to date, nothing new';
  }
  final parts = [
    '${run.filesUploaded} uploaded (${formatBytes(run.bytesUploaded)})',
    '${run.filesAlreadyBackedUp} already there',
    if (run.filesFailed > 0) '${run.filesFailed} failed',
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

/// The lines under the progress bar while a run goes on.
List<String> liveProgressLines(
  BackupActivity activity,
  BackupLiveProgress? progress,
  DateTime now, {
  String itemsWord = 'photos',
}) {
  if (progress == null) return const ['Getting ready…'];
  final checkedText = activity == BackupActivity.verifying
      ? '${formatCount(progress.itemsChecked)} of '
            '${formatCount(progress.itemsTotal)} files checked'
      : '${formatCount(progress.itemsChecked)} of '
            '~${formatCount(progress.itemsTotal)} $itemsWord checked';
  final speed = progress.bytesPerSecond(now);
  return [
    checkedText,
    '${formatCount(progress.filesUploaded)} uploaded · '
        '${formatBytes(progress.bytesUploaded)}'
        '${speed > 0 ? ' · ${formatBytes(speed.round())}/s' : ''}',
    if (progress.currentPath.isNotEmpty) 'Now: ${progress.currentPath}',
  ];
}
