/// The I/O side of the admin protocol: one Unix-socket connection per
/// command, like `haotrannas-server pair` does (D-041).
///
/// ```
///  connect <socket> ─► "<command>\n" ─► close our side ─► read lines until EOF
///                                         progress <n> lines ─► onProgress
/// ```
///
/// The socket is the server's `<data_dir>/admin.sock` on this PC, or the
/// local end of an [SshTunnel]. Author: Hao Tran.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'admin_codec.dart';

/// Why a command never got a reply.
class AdminLinkFailed implements Exception {
  const AdminLinkFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

class AdminLink {
  AdminLink(this.socketPath, {this.replyTimeout = const Duration(seconds: 10)});

  final String socketPath;

  /// Longest wait for the next line. A scrub sends `progress` lines while
  /// it runs, so this bounds the gap, not the whole command.
  final Duration replyTimeout;

  /// A reply larger than this is cut off (a device list is a few KiB).
  static const maxReplyBytes = 1 << 20;

  /// Sends [command] and returns its reply lines (without `progress`
  /// lines, which go to [onProgress]). Throws [AdminLinkFailed].
  Future<List<String>> send(
    String command, {
    void Function(int chunksChecked)? onProgress,
  }) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: replyTimeout,
      );
    } on SocketException catch (error) {
      throw AdminLinkFailed(
        'No server answers on $socketPath (${error.osError?.message ?? error.message}).',
      );
    }
    try {
      socket.write('$command\n');
      await socket.flush();
      // Our side is done: the server answers, sees the end and closes.
      unawaited(socket.close());
      final lines = <String>[];
      var replyBytes = 0;
      await for (final line
          in socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(replyTimeout)) {
        replyBytes += line.length + 1;
        if (replyBytes > maxReplyBytes) {
          throw const AdminLinkFailed('The admin reply is too large.');
        }
        final progress = parseProgress(line);
        if (progress != null) {
          onProgress?.call(progress);
        } else {
          lines.add(line);
        }
      }
      return lines;
    } on TimeoutException {
      throw const AdminLinkFailed('The server stopped answering.');
    } on SocketException catch (error) {
      throw AdminLinkFailed('The admin connection broke: ${error.message}');
    } on FormatException {
      throw const AdminLinkFailed('The admin reply is not valid text.');
    } finally {
      socket.destroy();
    }
  }
}
