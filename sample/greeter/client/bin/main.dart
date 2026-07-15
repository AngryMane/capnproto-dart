// Dart client that connects to the Rust Greeter server and calls greet().
//
// Run after starting the Rust server:
//   cargo run --manifest-path sample/greeter/server/Cargo.toml
//   dart run sample/greeter/client/bin/main.dart

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import '../../schema/greeter.capnp.dart';

Future<void> main() async {
  const host = '127.0.0.1';
  const port = 12345;

  print('[client] connecting to $host:$port ...');
  final conn = await RpcSystem.connect(Uri.parse('tcp://$host:$port'));
  print('[client] connected');

  final greeter = conn.bootstrap(GreeterClientFactory());

  // One-shot greet calls.
  final names = ['World', 'Cap\'n Proto', 'Dart'];
  for (final name in names) {
    print('[client] calling greet("$name")');
    final results = await greeter.greet((b) => b.name = name);
    print('[client] reply: "${results.reply ?? ''}"');
  }

  // newSession: obtain a GreetSession capability and use it.
  print('[client] calling newSession("Session User")');
  final session = await greeter.newSession((b) => b.name = 'Session User');
  print('[client] session capability obtained');

  for (int i = 1; i <= 3; i++) {
    print('[client] calling session.greet() #$i');
    final r = await session.greet((_) {});
    print('[client] reply: "${r.reply ?? ''}"');
  }

  await session.dispose();
  await conn.close();
  print('[client] done');
}
