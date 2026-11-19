/// Pairing this PC (spec §7), in three steps on one card.
///
/// ```
///  1 Find the NAS   search the LAN (mDNS) or type the address ─► connect
///  2 Compare ids    the id this PC sees = the id the NAS shows?  no ─► stop
///  3 Code           type it, or [Get code from NAS] through the admin socket
///                   (then the ids are compared for you) ─► paired ─► app
/// ```
///
/// Author: Hao Tran.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/client/pairing.dart';
import 'package:haotrannas_client/client/server_address.dart';
import 'package:haotrannas_client/discovery/discovery.dart';

import '../admin/admin_codec.dart';
import '../admin/admin_controller.dart';
import '../app/desktop_providers.dart';
import 'admin_page.dart';
import 'theme.dart';
import 'widgets.dart';

class PairingPage extends ConsumerStatefulWidget {
  const PairingPage({super.key});

  @override
  ConsumerState<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends ConsumerState<PairingPage> {
  final _addressController = TextEditingController();
  final _codeController = TextEditingController();
  List<DiscoveredServer>? _found;
  bool _isSearching = false;
  bool _isBusy = false;
  ServerAddress? _address;
  PairingAttempt? _attempt;
  bool _isIdConfirmed = false;

  /// The server id the admin socket gave with its code.
  String? _adminServerId;
  String? _problemTitle;
  String? _problem;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _addressController.dispose();
    _codeController.dispose();
    unawaited(_attempt?.close());
    super.dispose();
  }

  void _showProblem(String title, String message) => setState(() {
    _problemTitle = title;
    _problem = message;
  });

  Future<void> _search() async {
    setState(() => _isSearching = true);
    final found = await ref.read(serverFinderProvider)();
    if (!mounted) return;
    setState(() {
      _found = found;
      _isSearching = false;
    });
  }

  Future<void> _connect(ServerAddress address) async {
    setState(() {
      _isBusy = true;
      _problem = null;
    });
    try {
      final attempt = await ref.read(pairingOpenerProvider)(address);
      if (!mounted) {
        await attempt.close();
        return;
      }
      setState(() {
        _address = address;
        _attempt = attempt;
        _isIdConfirmed = false;
      });
    } on PairingFailed catch (failed) {
      if (mounted) {
        _showProblem(pairingFailureTitle(failed.kind), failed.message);
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _connectTyped() async {
    final address = ServerAddress.tryParse(_addressController.text);
    if (address == null) {
      _showProblem(
        'Check the address',
        'Type the NAS address like 192.168.1.5 or 192.168.1.5:47100.',
      );
      return;
    }
    await _connect(address);
  }

  Future<void> _startOver({String? title, String? message}) async {
    await _attempt?.close();
    if (!mounted) return;
    setState(() {
      _attempt = null;
      _address = null;
      _isIdConfirmed = false;
      _adminServerId = null;
      _codeController.clear();
      _problemTitle = title;
      _problem = message;
    });
  }

  /// Fills the code from the admin socket; the server id that came with
  /// it must match the one this connection sees.
  Future<void> _codeFromAdmin() async {
    final attempt = _attempt;
    if (attempt == null) return;
    setState(() => _isBusy = true);
    final result = await ref.read(adminProvider.notifier).createPairingCode();
    if (!mounted) return;
    setState(() => _isBusy = false);
    switch (result) {
      case AdminFailed(:final message):
        _showProblem('No code from the NAS', message);
      case AdminOk(value: final code)
          when code.serverShortId != attempt.serverShortId:
        await _startOver(
          title: 'Possible man-in-the-middle',
          message:
              'The NAS admin says its id is ${code.serverShortId}, but '
              'this connection sees ${attempt.serverShortId}. Pairing stopped.',
        );
      case AdminOk(value: final code):
        setState(() {
          _adminServerId = code.serverShortId;
          _isIdConfirmed = true;
          _codeController.text = code.code;
          _problem = null;
        });
        await _submit();
    }
  }

  Future<void> _submit() async {
    final attempt = _attempt;
    if (attempt == null || _isBusy) return;
    setState(() {
      _isBusy = true;
      _problem = null;
    });
    final result = await attempt.submitCode(_codeController.text.trim());
    if (!mounted) return;
    switch (result) {
      case PairingSucceeded(:final identity):
        final address = _address;
        try {
          await ref
              .read(identityStoreProvider)
              .save(
                address == null
                    ? identity
                    : identity.withAddresses(KnownAddresses(lastLan: address)),
              );
        } on Object catch (error) {
          if (!mounted) return;
          setState(() => _isBusy = false);
          _showProblem('Could not save the pairing', '$error');
          return;
        }
        await attempt.close();
        ref.invalidate(identityProvider);
      case PairingFailed(:final kind, :final message):
        final canTryAgain =
            (kind == PairingFailureKind.badCode ||
                kind == PairingFailureKind.badCodeFormat) &&
            attempt.isOpen;
        setState(() => _isBusy = false);
        _codeController.clear();
        if (canTryAgain) {
          _showProblem(pairingFailureTitle(kind), message);
        } else {
          await _startOver(title: pairingFailureTitle(kind), message: message);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final attempt = _attempt;
    final problem = _problem;
    final step = attempt == null ? 1 : (_isIdConfirmed ? 3 : 2);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.storage_rounded, size: 48, color: colors.primary),
                const SizedBox(height: 12),
                Text(
                  'Pair this PC with your NAS',
                  textAlign: TextAlign.center,
                  style: textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const HintText(
                  'Once paired, this PC backs up its folders and can restore '
                  'anything on the NAS.',
                ),
                const SizedBox(height: 24),
                _StepHeader(number: 1, title: 'Find the NAS', current: step),
                if (step == 1) _findStep(),
                _StepHeader(
                  number: 2,
                  title: 'Compare the server id',
                  current: step,
                ),
                if (step == 2 && attempt != null) _compareStep(attempt),
                _StepHeader(number: 3, title: 'Enter the code', current: step),
                if (step == 3) _codeStep(),
                if (problem != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: colors.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _problemTitle ?? 'Problem',
                            style: textTheme.titleSmall?.copyWith(
                              color: colors.onErrorContainer,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            problem,
                            style: TextStyle(color: colors.onErrorContainer),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_isBusy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _findStep() {
    final found = _found;
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isSearching)
            const HintText('Searching the network…')
          else if (found == null || found.isEmpty)
            const HintText(
              'No NAS found on this network. Type its address below.',
            )
          else
            for (final server in found)
              Card(
                child: ListTile(
                  key: Key('found.${server.ipv4Address.address}'),
                  leading: const Icon(Icons.dns),
                  title: Text(serverDisplayName(server.instanceName)),
                  subtitle: Text(
                    '${server.ipv4Address.address}:${server.port}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _isBusy
                      ? null
                      : () => _connect(
                          ServerAddress(
                            server.ipv4Address.address,
                            server.port,
                          ),
                        ),
                ),
              ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addressController,
                  decoration: const InputDecoration(
                    labelText: 'NAS address',
                    hintText: '192.168.1.5 or 192.168.1.5:47100',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _connectTyped(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _isBusy ? null : _connectTyped,
                child: const Text('Connect'),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _isSearching ? null : _search,
              icon: const Icon(Icons.refresh),
              label: const Text('Search again'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compareStep(PairingAttempt attempt) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HintText(
            'The NAS prints its id with the pairing code '
            '(haotrannas-server pair, or Pair a new device on another PC). '
            'It must be exactly this:',
          ),
          const SizedBox(height: 12),
          SelectableText(
            attempt.serverShortId,
            key: const Key('pairing.serverId'),
            style: textTheme.headlineMedium?.copyWith(letterSpacing: 2),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => setState(() => _isIdConfirmed = true),
                child: const Text('Same id'),
              ),
              OutlinedButton(
                onPressed: () => _startOver(
                  title: 'Pairing stopped',
                  message:
                      'Pair only when both ids are the same. Another '
                      'device may be pretending to be your NAS.',
                ),
                child: const Text('Different'),
              ),
              TextButton.icon(
                onPressed: _isBusy ? null : _codeFromAdmin,
                icon: const Icon(Icons.bolt),
                label: const Text('Pair in one click (NAS admin)'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) =>
                  AdminTargetDialog(initial: ref.read(adminProvider).target),
            ),
            child: const Text('Set up the NAS admin connection'),
          ),
        ],
      ),
    );
  }

  Widget _codeStep() {
    final colors = Theme.of(context).colorScheme;
    final adminServerId = _adminServerId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (adminServerId != null)
            StatusLine(
              color: okColor(colors),
              text: 'Server id $adminServerId checked through the NAS admin',
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('pairing.codeField'),
                  controller: _codeController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '6-digit code',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _isBusy ? null : _submit,
                child: const Text('Pair'),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _isBusy ? null : _codeFromAdmin,
              icon: const Icon(Icons.bolt),
              label: const Text('Get the code from the NAS'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.number,
    required this.title,
    required this.current,
  });

  final int number;
  final String title;
  final int current;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDone = number < current;
    final isActive = number == current;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: isDone || isActive
                ? colors.primary
                : colors.surfaceContainerHighest,
            foregroundColor: isDone || isActive
                ? colors.onPrimary
                : colors.onSurfaceVariant,
            child: isDone ? const Icon(Icons.check, size: 18) : Text('$number'),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: isActive || isDone ? null : colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// `haotrannas._haotrannas._tcp.local` → `haotrannas`.
String serverDisplayName(String instanceName) {
  final serviceStart = instanceName.indexOf('._haotrannas._tcp');
  return serviceStart > 0
      ? instanceName.substring(0, serviceStart)
      : instanceName;
}
