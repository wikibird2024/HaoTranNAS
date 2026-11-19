/// Reaches the NAS's admin socket over SSH (D-041): OpenSSH forwards a
/// local Unix socket to the remote one, so no new port is opened on the
/// NAS and the user's SSH keys are the only credential.
///
/// ```
///  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes
///      -L <private temp dir>/admin.sock:<remote data dir>/admin.sock <host>
///  wait until the local socket exists ─► AdminLink(local socket)
///  close() ─► kill ssh, delete the temp dir
/// ```
///
/// BatchMode: no password prompt (the app has no terminal); keys or the
/// SSH agent must work, as for `ssh <host>` in a terminal. ⚪ On the NAS
/// the SSH user needs access to admin.sock (mode 0600, user haotrannas):
/// a group for it is planned in M3n. Author: Hao Tran.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'admin_link.dart';

/// Starts `ssh`; tests pass a fake.
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

class SshTunnel {
  SshTunnel._(this._process, this._folder, this.localSocketPath);

  final Process _process;
  final Directory _folder;

  /// Connect an [AdminLink] here.
  final String localSocketPath;

  bool _isClosed = false;

  /// Opens the tunnel to [host] (`user@nas` or an ~/.ssh/config name) for
  /// [remoteSocketPath]. Throws [AdminLinkFailed] with ssh's own message.
  static Future<SshTunnel> open({
    required String host,
    required String remoteSocketPath,
    Duration timeout = const Duration(seconds: 15),
    ProcessStarter start = Process.start,
  }) async {
    if (host.trim().isEmpty || host.startsWith('-')) {
      throw const AdminLinkFailed('Enter the NAS as host or user@host.');
    }
    final folder = await Directory.systemTemp.createTemp('haotrannas-admin-');
    final localSocketPath = '${folder.path}/admin.sock';
    final Process process;
    try {
      process = await start('ssh', [
        '-N',
        '-o',
        'BatchMode=yes',
        '-o',
        'ExitOnForwardFailure=yes',
        '-o',
        'ConnectTimeout=${timeout.inSeconds}',
        '-L',
        '$localSocketPath:$remoteSocketPath',
        '--',
        host,
      ]);
    } on ProcessException catch (error) {
      await folder.delete(recursive: true);
      throw AdminLinkFailed('Cannot start ssh: ${error.message}');
    }
    final errorText = StringBuffer();
    final errorDone = process.stderr
        .transform(utf8.decoder)
        .listen(errorText.write)
        .asFuture<void>();
    var exitCode = -1;
    var hasExited = false;
    unawaited(
      process.exitCode.then((code) {
        exitCode = code;
        hasExited = true;
      }),
    );
    final deadline = DateTime.now().add(timeout);
    while (!hasExited && DateTime.now().isBefore(deadline)) {
      if (await FileSystemEntity.type(localSocketPath) ==
          FileSystemEntityType.unixDomainSock) {
        return SshTunnel._(process, folder, localSocketPath);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    process.kill();
    await errorDone.timeout(const Duration(seconds: 1), onTimeout: () {});
    await folder.delete(recursive: true);
    final sshSaid = errorText.toString().trim();
    throw AdminLinkFailed(
      hasExited
          ? 'ssh $host failed (exit $exitCode)${sshSaid.isEmpty ? '' : ': $sshSaid'}'
          : 'ssh $host did not open the tunnel within ${timeout.inSeconds} s.',
    );
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
    if (await _folder.exists()) await _folder.delete(recursive: true);
  }
}
