// Domain-layer boundary between the UI and Cap'n Proto RPC.
//
// This is the only file in the app that imports capnproto_dart_rpc or the
// generated schema. Everything it exposes to callers is a plain Dart type
// (String, bool, void) — never a GreeterClient, a GreetSessionClient, or a
// generated Reader/Builder. That keeps the UI layer free to be tested or
// refactored without touching RPC code, and means a schema change only ever
// requires editing this file.
//
// The GreetSession capability returned by newSession() is a live remote
// object, not passive data, so it can't become a DTO field the way the
// reply text can — it stays private state behind sessionGreet() instead of
// being handed to callers directly.

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:greeter_flutter_client/schema/greeter.capnp.dart';

class GreeterRepository {
  RpcConnection? _conn;
  GreeterClient? _greeter;
  GreetSessionClient? _session;

  bool get isConnected => _greeter != null;
  bool get hasSession => _session != null;

  Future<void> connect(String host, int port) async {
    final conn = await RpcSystem.connect(Uri.parse('tcp://$host:$port'));
    _conn = conn;
    _greeter = conn.bootstrap(GreeterClientFactory());
  }

  /// Disposes the session (if any) and closes the connection. Safe to call
  /// repeatedly or when nothing is connected.
  Future<void> disconnect() async {
    await _session?.dispose();
    await _conn?.close();
    _session = null;
    _conn = null;
    _greeter = null;
  }

  Future<String> greet(String name) async {
    final results = await _requireGreeter().greet((b) => b.name = name);
    return results.reply ?? '';
  }

  Future<void> startSession(String name) async {
    final result = await _requireGreeter().newSession((b) => b.name = name);
    await _session?.dispose();
    _session = result.session;
  }

  Future<String> sessionGreet() async {
    final session = _session;
    if (session == null) {
      throw StateError('no active session; call startSession() first');
    }
    final r = await session.greet((_) {});
    return r.reply ?? '';
  }

  GreeterClient _requireGreeter() {
    final greeter = _greeter;
    if (greeter == null) {
      throw StateError('not connected; call connect() first');
    }
    return greeter;
  }
}
