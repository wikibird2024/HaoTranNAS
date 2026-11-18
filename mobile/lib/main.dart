import 'package:flutter/material.dart';

void main() => runApp(const HaoTranNasApp());

/// Placeholder until the pairing and status screens exist (lib/ui/).
class HaoTranNasApp extends StatelessWidget {
  const HaoTranNasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HaoTranNAS',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      home: Scaffold(
        appBar: AppBar(title: const Text('HaoTranNAS')),
        body: const Center(child: Text('Backup to my own server: coming soon')),
      ),
    );
  }
}
