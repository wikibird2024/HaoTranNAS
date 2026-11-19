/// Browse the backups on the NAS (spec §9) and restore one file to the
/// phone.
///
/// ```
///  BrowseScreen (ListDevices) ─► FolderScreen (ListDir, page by page as
///  the list scrolls) ─► FolderScreen … ─► FileDetailsScreen
///                                         Restore: progress + Cancel
/// ```
///
/// Everything goes through `RemoteFiles`, so widget tests use a fake.
/// Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../client/download_engine.dart';
import '../protocol/messages.dart';
import 'formatting.dart';

/// Entries asked for per ListDir page (the spec allows up to 1000; a
/// smaller page shows the first rows sooner).
const int folderPageEntries = 200;

/// Lists every paired device; tap one to open its root folder.
class BrowseScreen extends ConsumerWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(remoteFilesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Backups')),
      body: files == null
          ? _NotConnected(
              onConnect: () =>
                  ref.read(serverConnectionProvider.notifier).connect(),
            )
          : _DeviceList(files: files),
    );
  }
}

class _NotConnected extends StatelessWidget {
  const _NotConnected({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Not connected to the NAS.'),
        const SizedBox(height: 8),
        FilledButton(onPressed: onConnect, child: const Text('Connect')),
      ],
    ),
  );
}

class _DeviceList extends StatefulWidget {
  const _DeviceList({required this.files});

  final RemoteFiles files;

  @override
  State<_DeviceList> createState() => _DeviceListState();
}

class _DeviceListState extends State<_DeviceList> {
  late Future<List<DeviceEntry>> _devices = widget.files.listDevices();

  @override
  void didUpdateWidget(_DeviceList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.files != widget.files) {
      _devices = widget.files.listDevices();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DeviceEntry>>(
    future: _devices,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _ProblemText(
          '${snapshot.error}',
          onRetry: () => setState(() => _devices = widget.files.listDevices()),
        );
      }
      final devices = snapshot.data;
      if (devices == null) {
        return const Center(child: CircularProgressIndicator());
      }
      if (devices.isEmpty) {
        return const Center(child: Text('No devices on the NAS.'));
      }
      return ListView(
        children: [
          for (final device in devices)
            ListTile(
              leading: Icon(
                device.isCaller ? Icons.smartphone : Icons.devices_other,
              ),
              title: Text(
                device.isCaller ? '${device.name} (this phone)' : device.name,
              ),
              subtitle: Text('Paired ${formatTimeMs(device.pairedAtMs)}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FolderScreen(
                    files: widget.files,
                    deviceId: device.deviceId,
                    deviceName: device.name,
                    path: '',
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _ProblemText extends StatelessWidget {
  const _ProblemText(this.text, {required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

/// One folder of one device; loads the next page when the list reaches
/// its end.
class FolderScreen extends StatefulWidget {
  const FolderScreen({
    super.key,
    required this.files,
    required this.deviceId,
    required this.deviceName,
    required this.path,
    this.pageEntries = folderPageEntries,
  });

  final RemoteFiles files;
  final int deviceId;
  final String deviceName;

  /// "" = the device's root.
  final String path;
  final int pageEntries;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  final _entries = <DirEntry>[];
  bool _hasMore = true;
  bool _isLoading = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _loadNextPage();
  }

  Future<void> _loadNextPage() async {
    if (_isLoading || !_hasMore) return;
    setState(() {
      _isLoading = true;
      _problem = null;
    });
    try {
      final page = await widget.files.listDirPage(
        deviceId: widget.deviceId,
        path: widget.path,
        startAfter: _entries.isEmpty ? '' : _entries.last.name,
        maxEntries: widget.pageEntries,
      );
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _hasMore = page.hasMore;
        _isLoading = false;
      });
    } on BrowseFailed catch (failed) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _problem = failed.kind == BrowseFailureKind.notFound
            ? 'This folder is not on the NAS (any more).'
            : failed.message;
      });
    }
  }

  String _childPath(String name) =>
      widget.path.isEmpty ? name : '${widget.path}/$name';

  void _open(DirEntry entry) {
    final childPath = _childPath(entry.name);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => entry.kind == DirEntryKind.directory
            ? FolderScreen(
                files: widget.files,
                deviceId: widget.deviceId,
                deviceName: widget.deviceName,
                path: childPath,
                pageEntries: widget.pageEntries,
              )
            : FileDetailsScreen(
                files: widget.files,
                deviceId: widget.deviceId,
                remotePath: childPath,
                entry: entry,
              ),
      ),
    );
  }

  Widget _tailTile() {
    final problem = _problem;
    if (problem != null) {
      return _ProblemText(problem, onRetry: _loadNextPage);
    }
    // Reached the end of what is loaded: ask for the next page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadNextPage();
    });
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.path.isEmpty
        ? widget.deviceName
        : widget.path.split('/').last;
    final hasTail = _hasMore || _problem != null;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: !hasTail && _entries.isEmpty
          ? const Center(child: Text('Nothing backed up here yet.'))
          : ListView.builder(
              itemCount: _entries.length + (hasTail ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _entries.length) return _tailTile();
                final entry = _entries[index];
                final isFolder = entry.kind == DirEntryKind.directory;
                return ListTile(
                  leading: Icon(
                    isFolder ? Icons.folder : Icons.insert_drive_file,
                  ),
                  title: Text(entry.name),
                  subtitle: isFolder
                      ? null
                      : Text(
                          '${formatBytes(entry.sizeBytes)} · '
                          '${formatTimeMs(entry.modifiedTimeMs)}',
                        ),
                  trailing: isFolder ? const Icon(Icons.chevron_right) : null,
                  onTap: () => _open(entry),
                );
              },
            ),
    );
  }
}

/// Size, date and version of one file, and Restore with progress.
class FileDetailsScreen extends ConsumerStatefulWidget {
  const FileDetailsScreen({
    super.key,
    required this.files,
    required this.deviceId,
    required this.remotePath,
    required this.entry,
  });

  final RemoteFiles files;
  final int deviceId;
  final String remotePath;
  final DirEntry entry;

  @override
  ConsumerState<FileDetailsScreen> createState() => _FileDetailsScreenState();
}

class _FileDetailsScreenState extends ConsumerState<FileDetailsScreen> {
  DownloadCancel? _cancel;
  DownloadProgress? _progress;
  DownloadResult? _result;

  bool get _isRestoring => _cancel != null;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    final cancel = DownloadCancel();
    setState(() {
      _cancel = cancel;
      _progress = null;
      _result = null;
    });
    final result = await restoreToPhone(
      files: widget.files,
      restoreFolder: ref.read(restoreFolderProvider),
      deviceId: widget.deviceId,
      remotePath: widget.remotePath,
      versionId: widget.entry.versionId,
      cancel: cancel,
      addToGallery: ref.read(addToGalleryProvider),
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    setState(() {
      _cancel = null;
      _result = result;
    });
  }

  String _resultText(DownloadResult result) => switch (result) {
    DownloadDone(:final outputPath) => 'Saved to $outputPath',
    DownloadCancelled() => 'Cancelled. Nothing was saved.',
    DownloadFailed(:final kind, :final message) => switch (kind) {
      DownloadFailureKind.notFound => 'Not on the NAS any more.',
      DownloadFailureKind.connectionLost =>
        'The connection to the NAS ended. Nothing was saved.',
      DownloadFailureKind.chunkHashMismatch ||
      DownloadFailureKind.chunkSizeWrong ||
      DownloadFailureKind.fileHashMismatch =>
        'The file from the NAS is damaged ($message). Nothing was saved.',
      _ => 'Failed: $message',
    },
  };

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final progress = _progress;
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: Text(entry.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DetailRow('Path', widget.remotePath),
          _DetailRow('Size', formatBytes(entry.sizeBytes)),
          _DetailRow('Changed', formatTimeMs(entry.modifiedTimeMs)),
          _DetailRow('Version', '${entry.versionId}'),
          const SizedBox(height: 16),
          if (_isRestoring) ...[
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: 8),
            Text(
              progress == null
                  ? 'Starting…'
                  : '${formatBytes(progress.bytesDone)} of '
                        '${formatBytes(progress.sizeBytes)}',
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _cancel?.cancel(),
              child: const Text('Cancel'),
            ),
          ] else
            FilledButton.icon(
              onPressed: _restore,
              icon: const Icon(Icons.download),
              label: const Text('Restore to phone'),
            ),
          if (result != null) ...[
            const SizedBox(height: 16),
            Text(_resultText(result)),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
