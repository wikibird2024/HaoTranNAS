/// Files: what is on the NAS, per device, and restore to this PC.
///
/// ```
///  ┌ Devices ─────┐ ┌ Documents / notes ───────────── [Restore folder] ┐
///  │ ▸ This PC    │ │ 📁 drafts                                         │
///  │   Pixel      │ │ 📄 a.txt      12 KB   2026-11-19 14:02  [Restore]  │
///  └──────────────┘ └───────────────────────────────────────────────────┘
///  Restore ─► pick a PC folder ─► download (SHA-256 checked) ─► "Restored, hash matches"
/// ```
///
/// Author: Hao Tran.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/client/download_engine.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_client/text/formatting.dart';

import '../app/desktop_providers.dart';
import '../files/restore.dart';
import 'home_shell.dart';
import 'widgets.dart';

class FilesPage extends ConsumerWidget {
  const FilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(remoteFilesProvider);
    // Built fresh each time the page opens, so a backup that just ran
    // shows up; hidden, it lists nothing.
    final isShown = ref.watch(currentPageProvider) == AppPage.files;
    final reloads = ref.watch(filesReloadProvider);
    return PageFrame(
      title: 'Files',
      subtitle:
          'Everything backed up on the NAS. Restoring never replaces '
          'a file on this PC.',
      actions: [
        if (files != null)
          IconButton(
            tooltip: 'Reload',
            onPressed: () => ref.read(filesReloadProvider.notifier).reload(),
            icon: const Icon(Icons.refresh),
          ),
      ],
      children: [
        if (files == null)
          SectionCard(
            icon: Icons.cloud_off_outlined,
            title: 'Not connected',
            trailing: FilledButton(
              onPressed: () =>
                  ref.read(serverConnectionProvider.notifier).connect(),
              child: const Text('Connect'),
            ),
            child: const HintText(
              'Connect to the NAS to browse the backed-up files.',
            ),
          )
        else if (isShown)
          _Browser(key: ValueKey((files, reloads)), files: files),
      ],
    );
  }
}

/// Bumped by the Reload button: the browser starts over.
final filesReloadProvider = NotifierProvider<FilesReload, int>(FilesReload.new);

class FilesReload extends Notifier<int> {
  @override
  int build() => 0;

  void reload() => state++;
}

class _Browser extends StatefulWidget {
  const _Browser({super.key, required this.files});

  final RemoteFiles files;

  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  List<DeviceEntry>? _devices;
  DeviceEntry? _device;
  String _path = '';
  final _entries = <DirEntry>[];
  bool _hasMore = false;
  bool _isLoading = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDevices());
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await widget.files.listDevices();
      if (!mounted) return;
      // This PC first, then by name.
      devices.sort((first, second) {
        if (first.isCaller != second.isCaller) return first.isCaller ? -1 : 1;
        return first.name.compareTo(second.name);
      });
      setState(() => _devices = devices);
      if (devices.isNotEmpty) await _open(devices.first, '');
    } on BrowseFailed catch (error) {
      if (mounted) setState(() => _problem = error.message);
    }
  }

  Future<void> _open(DeviceEntry device, String path) async {
    setState(() {
      _device = device;
      _path = path;
      _entries.clear();
      _hasMore = true;
      _problem = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final device = _device;
    if (device == null || _isLoading || !_hasMore) return;
    setState(() => _isLoading = true);
    try {
      final page = await widget.files.listDirPage(
        deviceId: device.deviceId,
        path: _path,
        startAfter: _entries.isEmpty ? '' : _entries.last.name,
      );
      if (!mounted || device != _device) return;
      setState(() {
        _entries.addAll(page.entries);
        _hasMore = page.hasMore;
      });
    } on BrowseFailed catch (error) {
      if (mounted) setState(() => _problem = error.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<Directory?> _pickTarget() async {
    final path = await getDirectoryPath(confirmButtonText: 'Restore here');
    return path == null ? null : Directory(path);
  }

  Future<void> _restoreFile(DirEntry entry) async {
    final device = _device;
    final target = await _pickTarget();
    if (device == null || target == null || !mounted) return;
    final remotePath = joinRemotePath(_path, entry.name);
    final cancel = DownloadCancel();
    final progress = ValueNotifier<String>('Starting…');
    final finished = restoreFile(
      files: widget.files,
      deviceId: device.deviceId,
      remotePath: remotePath,
      targetFolder: target,
      cancel: cancel,
      onProgress: (step) => progress.value =
          '${formatBytes(step.bytesDone)} of ${formatBytes(step.sizeBytes)}',
    );
    final result = await _runWithDialog(
      title: 'Restoring ${entry.name}',
      progress: progress,
      cancel: cancel,
      work: finished,
    );
    if (!mounted) return;
    showNote(context, switch (result) {
      DownloadDone(:final outputPath) => 'Restored, hash matches: $outputPath',
      DownloadCancelled() => 'Restore cancelled.',
      DownloadFailed(:final message) => 'Restore failed: $message',
    });
  }

  Future<void> _restoreFolder() async {
    final device = _device;
    final target = await _pickTarget();
    if (device == null || target == null || !mounted) return;
    final cancel = DownloadCancel();
    final progress = ValueNotifier<String>('Listing…');
    final summary = await _runWithDialog(
      title: 'Restoring ${remoteNameOf(_path)}',
      progress: progress,
      cancel: cancel,
      work: restoreFolder(
        files: widget.files,
        deviceId: device.deviceId,
        remoteFolder: _path,
        targetFolder: target,
        cancel: cancel,
        onProgress: (done, remotePath) =>
            progress.value = '${formatCount(done)} files done\n$remotePath',
      ),
    );
    if (!mounted) return;
    final restoredText =
        '${formatCount(summary.filesRestored)} files '
        '(${formatBytes(summary.bytesRestored)})';
    showNote(
      context,
      summary.isComplete
          ? 'Restored $restoredText, every hash matches.'
          : summary.isCancelled
          ? 'Cancelled after $restoredText.'
          : 'Restored $restoredText; ${summary.failures.length} failed'
                '${summary.listingProblem == null ? '' : '; listing stopped: ${summary.listingProblem}'}.',
    );
  }

  /// Shows a progress dialog with Cancel while [work] runs.
  Future<T> _runWithDialog<T>({
    required String title,
    required ValueNotifier<String> progress,
    required DownloadCancel cancel,
    required Future<T> work,
  }) async {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                ValueListenableBuilder(
                  valueListenable: progress,
                  builder: (context, text, _) =>
                      Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: cancel.cancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
    try {
      return await work;
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final problem = _problem;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 240,
          child: SectionCard(
            icon: Icons.devices_outlined,
            title: 'Devices',
            child: devices == null
                ? const LinearProgressIndicator()
                : Column(
                    children: [
                      for (final device in devices)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          selected: device.deviceId == _device?.deviceId,
                          leading: Icon(
                            device.isCaller ? Icons.computer : Icons.smartphone,
                          ),
                          title: Text(
                            device.isCaller ? 'This PC' : device.name,
                          ),
                          subtitle: Text(
                            'paired ${formatTimeMs(device.pairedAtMs)}',
                          ),
                          onTap: () => _open(device, ''),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: SectionCard(
            icon: Icons.folder_open_outlined,
            title: _device == null ? 'Files' : _breadcrumbTitle(),
            trailing: _path.isEmpty
                ? null
                : Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => _open(_device!, _parentPath()),
                        icon: const Icon(Icons.arrow_upward),
                        label: const Text('Up'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _restoreFolder,
                        icon: const Icon(Icons.download),
                        label: const Text('Restore folder'),
                      ),
                    ],
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (problem != null) ProblemText(problem),
                if (_entries.isEmpty && !_isLoading && problem == null)
                  const HintText('Nothing backed up here yet.'),
                for (final entry in _entries) _entryRow(entry),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  )
                else if (_hasMore)
                  TextButton(
                    onPressed: _loadMore,
                    child: const Text('Load more'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _breadcrumbTitle() {
    final device = _device!;
    final deviceName = device.isCaller ? 'This PC' : device.name;
    return _path.isEmpty
        ? deviceName
        : '$deviceName / ${_path.replaceAll('/', ' / ')}';
  }

  String _parentPath() {
    final slash = _path.lastIndexOf('/');
    return slash < 0 ? '' : _path.substring(0, slash);
  }

  Widget _entryRow(DirEntry entry) {
    final isFolder = entry.kind == DirEntryKind.directory;
    return ListTile(
      key: Key('entry.${entry.name}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(isFolder ? Icons.folder : Icons.insert_drive_file_outlined),
      title: Text(entry.name),
      subtitle: isFolder
          ? null
          : Text(
              '${formatBytes(entry.sizeBytes)} · ${formatTimeMs(entry.modifiedTimeMs)}',
            ),
      trailing: isFolder
          ? const Icon(Icons.chevron_right)
          : TextButton.icon(
              onPressed: () => _restoreFile(entry),
              icon: const Icon(Icons.download),
              label: const Text('Restore'),
            ),
      onTap: isFolder
          ? () => _open(_device!, joinRemotePath(_path, entry.name))
          : null,
    );
  }
}
