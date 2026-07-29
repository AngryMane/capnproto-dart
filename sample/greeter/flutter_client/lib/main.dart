// Flutter (Linux desktop) client that connects to the Rust Greeter server
// and calls greet() / newSession(), mirroring sample/greeter/client/bin/main.dart
// but through a GUI instead of the console.
//
// Run after starting the Rust server:
//   cargo run --manifest-path sample/greeter/server/Cargo.toml
//   cd sample/greeter/flutter_client && flutter run -d linux
//
// This file never imports capnproto_dart_rpc or the generated schema —
// see greeter_repository.dart for the RPC boundary.

import 'dart:async';

import 'package:flutter/material.dart';

import 'greeter_repository.dart';

void main() => runApp(const GreeterApp());

class GreeterApp extends StatelessWidget {
  const GreeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Greeter (Cap'n Proto RPC)",
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const GreeterPage(),
    );
  }
}

class GreeterPage extends StatefulWidget {
  const GreeterPage({super.key});

  @override
  State<GreeterPage> createState() => _GreeterPageState();
}

class _GreeterPageState extends State<GreeterPage> {
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '12345');
  final _nameController = TextEditingController(text: 'World');
  final _log = <String>[];
  final _repository = GreeterRepository();

  bool _busy = false;

  @override
  void dispose() {
    // Best-effort cleanup; the widget tree is going away regardless of
    // whether this finishes.
    unawaited(_repository.disconnect());
    _hostController.dispose();
    _portController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _appendLog(String message) {
    setState(() => _log.add(message));
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null) {
      _appendLog('✗ enter a valid host and port');
      return;
    }
    setState(() => _busy = true);
    _appendLog('connecting to $host:$port ...');
    try {
      await _repository.connect(host, port);
      // The widget can be disposed while this await is in flight (e.g. the
      // user navigates away). Nobody else owns the repository, so it's on
      // us to tear it down instead of leaking the connection.
      if (!mounted) {
        await _repository.disconnect();
        return;
      }
      setState(() {});
      _appendLog('connected');
    } catch (error) {
      if (mounted) _appendLog('✗ connect failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await _repository.disconnect();
    if (!mounted) return;
    _appendLog('disconnected');
    setState(() => _busy = false);
  }

  Future<void> _greetOnce() async {
    if (!_repository.isConnected) return;
    final name = _nameController.text;
    setState(() => _busy = true);
    _appendLog('calling greet("$name")');
    try {
      final reply = await _repository.greet(name);
      if (!mounted) return;
      _appendLog('reply: "$reply"');
    } catch (error) {
      if (mounted) _appendLog('✗ greet failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newSession() async {
    if (!_repository.isConnected) return;
    final name = _nameController.text;
    setState(() => _busy = true);
    _appendLog('calling newSession("$name")');
    try {
      await _repository.startSession(name);
      // Same reasoning as _connect(): if nobody is left to own the
      // repository, tear it down ourselves rather than leak the session.
      if (!mounted) {
        await _repository.disconnect();
        return;
      }
      setState(() {});
      _appendLog('session capability obtained');
    } catch (error) {
      if (mounted) _appendLog('✗ newSession failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sessionGreet() async {
    if (!_repository.hasSession) return;
    setState(() => _busy = true);
    _appendLog('calling session.greet()');
    try {
      final reply = await _repository.sessionGreet();
      if (!mounted) return;
      _appendLog('reply: "$reply"');
    } catch (error) {
      if (mounted) _appendLog('✗ session.greet failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _repository.isConnected;
    return Scaffold(
      appBar: AppBar(title: const Text('Greeter Flutter Client')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hostController,
                    enabled: !connected,
                    decoration: const InputDecoration(labelText: 'Host'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _portController,
                    enabled: !connected,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : (connected ? _disconnect : _connect),
                  child: Text(connected ? 'Disconnect' : 'Connect'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              enabled: connected,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: connected && !_busy ? _greetOnce : null,
                  child: const Text('Greet (one-shot)'),
                ),
                ElevatedButton(
                  onPressed: connected && !_busy ? _newSession : null,
                  child: const Text('New session'),
                ),
                ElevatedButton(
                  onPressed: connected && _repository.hasSession && !_busy
                      ? _sessionGreet
                      : null,
                  child: const Text('Session greet'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: Card(
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  reverse: true,
                  itemCount: _log.length,
                  itemBuilder: (context, index) {
                    final message = _log[_log.length - 1 - index];
                    return Text(
                      message,
                      style: const TextStyle(fontFamily: 'monospace'),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
