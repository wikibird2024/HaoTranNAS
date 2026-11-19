/// Pairing (spec §7): find the NAS, let the user compare its short id,
/// type the 6-digit code, show the result.
///
/// ```
///  find ──(search Wi-Fi or type address)──► connecting ──► compare id
///   ▲                                                       │ same? no ─► stop (warn)
///   │                                                       ▼ yes
///   └──── closed / MITM / not allowed ◄──── enter code ──► paired ─► Done
///                                          ▲ wrong code, tries left
/// ```
///
/// The screen talks to [PairingAttempt], not to `PairingSession`
/// directly, so widget tests can play the server. Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_client/client/pairing.dart';
import 'package:haotrannas_client/client/server_address.dart';
import 'package:haotrannas_client/discovery/discovery.dart';
import 'package:haotrannas_client/protocol/limits.dart';

import '../app/providers.dart';

enum _PairingStep { findServer, connecting, compareId, enterCode, paired }

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({
    super.key,
    required this.savePairing,
    required this.onDone,
  });

  /// Saves the new identity at once (before the user taps Done).
  final Future<void> Function(DeviceIdentity identity) savePairing;

  /// The user tapped Done after pairing.
  final VoidCallback onDone;

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final _addressController = TextEditingController();
  final _codeController = TextEditingController();

  _PairingStep _step = _PairingStep.findServer;
  PairingAttempt? _attempt;
  ServerAddress? _address;
  List<DiscoveredServer>? _foundServers;
  bool _isSearching = false;
  bool _isSubmitting = false;
  String? _problemTitle;
  String? _problemText;
  bool _isAlarm = false;

  @override
  void dispose() {
    _attempt?.close();
    _addressController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _showProblem(String title, String text, {bool isAlarm = false}) {
    _problemTitle = title;
    _problemText = text;
    _isAlarm = isAlarm;
  }

  void _clearProblem() {
    _problemTitle = null;
    _problemText = null;
    _isAlarm = false;
  }

  Future<void> _search() async {
    setState(() {
      _isSearching = true;
      _foundServers = null;
      _clearProblem();
    });
    final servers = await ref.read(serverFinderProvider)();
    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _foundServers = servers;
    });
  }

  Future<void> _connectTyped() async {
    final address = ServerAddress.tryParse(_addressController.text);
    if (address == null) {
      setState(
        () => _showProblem(
          'Check the address',
          'Type the NAS address like 192.168.1.5 or 192.168.1.5:47100.',
        ),
      );
      return;
    }
    await _connect(address);
  }

  Future<void> _connect(ServerAddress address) async {
    setState(() {
      _step = _PairingStep.connecting;
      _address = address;
      _clearProblem();
    });
    try {
      final attempt = await ref.read(pairingOpenerProvider)(address);
      if (!mounted) {
        await attempt.close();
        return;
      }
      setState(() {
        _attempt = attempt;
        _step = _PairingStep.compareId;
      });
    } on PairingFailed catch (failed) {
      if (!mounted) return;
      setState(() {
        _step = _PairingStep.findServer;
        _showProblem(pairingFailureTitle(failed.kind), failed.message);
      });
    }
  }

  Future<void> _stopAfterIdMismatch() async {
    await _attempt?.close();
    if (!mounted) return;
    setState(() {
      _attempt = null;
      _step = _PairingStep.findServer;
      _showProblem(
        'Pairing stopped',
        'Pair only when both ids are the same. Another device may be '
            'pretending to be your NAS.',
        isAlarm: true,
      );
    });
  }

  Future<void> _submitCode() async {
    final attempt = _attempt;
    if (attempt == null || _isSubmitting) return;
    setState(() {
      _isSubmitting = true;
      _clearProblem();
    });
    final result = await attempt.submitCode(_codeController.text.trim());
    if (!mounted) return;
    switch (result) {
      case PairingSucceeded(:final identity):
        final address = _address;
        try {
          await widget.savePairing(
            address == null
                ? identity
                : identity.withAddresses(KnownAddresses(lastLan: address)),
          );
        } on Object catch (error) {
          if (!mounted) return;
          setState(() {
            _isSubmitting = false;
            _showProblem('Could not save the pairing', '$error');
          });
          return;
        }
        if (!mounted) return;
        setState(() {
          _isSubmitting = false;
          _step = _PairingStep.paired;
        });
      case PairingFailed(:final kind, :final message):
        final canTryAgain =
            (kind == PairingFailureKind.badCode ||
                kind == PairingFailureKind.badCodeFormat) &&
            attempt.isOpen;
        if (!canTryAgain) await attempt.close();
        if (!mounted) return;
        setState(() {
          _isSubmitting = false;
          _codeController.clear();
          if (!canTryAgain) {
            _attempt = null;
            _step = _PairingStep.findServer;
          }
          _showProblem(
            pairingFailureTitle(kind),
            message,
            isAlarm:
                kind == PairingFailureKind.serverMismatch ||
                kind == PairingFailureKind.shortIdMismatch,
          );
        });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pair with your NAS')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_problemTitle != null)
            _ProblemCard(
              title: _problemTitle!,
              text: _problemText ?? '',
              isAlarm: _isAlarm,
            ),
          ...switch (_step) {
            _PairingStep.findServer => _findServerParts(context),
            _PairingStep.connecting => _connectingParts(context),
            _PairingStep.compareId => _compareIdParts(context),
            _PairingStep.enterCode => _enterCodeParts(context),
            _PairingStep.paired => _pairedParts(context),
          },
        ],
      ),
    ),
  );

  List<Widget> _findServerParts(BuildContext context) {
    final servers = _foundServers;
    return [
      const Text(
        'On the NAS, run: haotrannas-server pair\n'
        'It shows a code and a server id.',
      ),
      const SizedBox(height: 16),
      FilledButton.tonalIcon(
        onPressed: _isSearching ? null : _search,
        icon: _isSearching
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_find),
        label: Text(_isSearching ? 'Searching…' : 'Search on Wi-Fi'),
      ),
      if (servers != null && servers.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('No NAS found. Type its address below.'),
        ),
      if (servers != null)
        for (final server in servers)
          ListTile(
            leading: const Icon(Icons.dns),
            title: Text(server.instanceName.split('.').first),
            subtitle: Text('${server.ipv4Address.address}:${server.port}'),
            onTap: () => _connect(
              ServerAddress(server.ipv4Address.address, server.port),
            ),
          ),
      const SizedBox(height: 24),
      TextField(
        key: const Key('pairing.address'),
        controller: _addressController,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'NAS address',
          hintText: '192.168.1.5',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _connectTyped(),
      ),
      const SizedBox(height: 8),
      FilledButton(onPressed: _connectTyped, child: const Text('Connect')),
    ];
  }

  List<Widget> _connectingParts(BuildContext context) => [
    const SizedBox(height: 32),
    const Center(child: CircularProgressIndicator()),
    const SizedBox(height: 16),
    Center(child: Text('Connecting to $_address…')),
  ];

  List<Widget> _compareIdParts(BuildContext context) => [
    const Text('Server id'),
    const SizedBox(height: 8),
    _ShortIdText(_attempt?.serverShortId ?? ''),
    const SizedBox(height: 16),
    Text(
      'Does the NAS show the same id?',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: () => setState(() => _step = _PairingStep.enterCode),
      child: const Text('Yes, same id'),
    ),
    const SizedBox(height: 8),
    OutlinedButton(
      onPressed: _stopAfterIdMismatch,
      child: const Text('No, stop'),
    ),
  ];

  List<Widget> _enterCodeParts(BuildContext context) => [
    Text('Server id ${_attempt?.serverShortId ?? ''}'),
    const SizedBox(height: 16),
    TextField(
      key: const Key('pairing.code'),
      controller: _codeController,
      autofocus: true,
      keyboardType: TextInputType.number,
      maxLength: pairingCodeDigits,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: Theme.of(context).textTheme.headlineSmall,
      decoration: const InputDecoration(
        labelText: 'Code shown on the NAS',
        border: OutlineInputBorder(),
      ),
      onSubmitted: (_) => _submitCode(),
    ),
    const SizedBox(height: 8),
    FilledButton(
      onPressed: _isSubmitting ? null : _submitCode,
      child: Text(_isSubmitting ? 'Pairing…' : 'Pair'),
    ),
  ];

  List<Widget> _pairedParts(BuildContext context) => [
    const SizedBox(height: 16),
    Icon(
      Icons.check_circle,
      size: 64,
      color: Theme.of(context).colorScheme.primary,
    ),
    const SizedBox(height: 8),
    Center(
      child: Text('Paired', style: Theme.of(context).textTheme.headlineSmall),
    ),
    const SizedBox(height: 8),
    Center(child: Text('Server id ${_attempt?.serverShortId ?? ''}')),
    const SizedBox(height: 24),
    FilledButton(onPressed: widget.onDone, child: const Text('Done')),
  ];
}

class _ShortIdText extends StatelessWidget {
  const _ShortIdText(this.shortIdText);

  final String shortIdText;

  @override
  Widget build(BuildContext context) => Center(
    child: SelectableText(
      shortIdText,
      style: Theme.of(context).textTheme.displaySmall
          ?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.bold),
    ),
  );
}

class _ProblemCard extends StatelessWidget {
  const _ProblemCard({
    required this.title,
    required this.text,
    required this.isAlarm,
  });

  final String title;
  final String text;
  final bool isAlarm;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: isAlarm ? colors.errorContainer : colors.surfaceContainerHighest,
      child: ListTile(
        leading: Icon(isAlarm ? Icons.gpp_bad : Icons.info_outline),
        title: Text(title),
        subtitle: Text(text),
      ),
    );
  }
}
