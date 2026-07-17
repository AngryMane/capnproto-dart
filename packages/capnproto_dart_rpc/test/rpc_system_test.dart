import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:test/test.dart';

class _RawCapabilityFactory extends CapabilityFactory<Capability> {
  @override
  Capability fromCapability(Capability cap) => cap;
}

// Minimal validly-framed message (1 segment, 1 word, null root pointer) —
// enough to get past decoding so the call reaches NullCapability.dispatch(),
// which is what's actually under test here.
final _emptyParams = Uint8List.fromList(
  [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
);

void main() {
  group('RpcSystem.serve / RpcSystem.connect (TCP)', () {
    test(
      'server.close() tears down already-accepted client connections, not '
      'just the listening socket',
      () async {
        // Regression test: RpcServer.close() previously only closed the
        // listening ServerSocket — accepted client connections (and their
        // underlying TCP sockets) were never tracked, so they stayed open
        // indefinitely after close().
        final server = await RpcSystem.serve(
          Uri.parse('tcp://127.0.0.1:0'),
          NullCapability(),
        );
        addTearDown(server.close);

        final client = await RpcSystem.connect(
          Uri.parse('tcp://127.0.0.1:${server.port}'),
        );

        // Confirm the connection is actually up before closing the server:
        // bootstrap() alone doesn't wait for the handshake, so do a real
        // (albeit unsupported-on-NullCapability) dispatch and observe a
        // clean RPC-level exception rather than a connection error.
        final boot = client.bootstrap(_RawCapabilityFactory());
        await expectLater(
          boot.dispatch(0, 0, _emptyParams),
          throwsA(isA<RpcException>()),
        );

        await server.close();

        // Give the client's incoming stream a moment to observe the server
        // socket closing.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // The connection server.close() was supposed to tear down must now
        // be closed: a new call on it must fail as "connection closed" (or
        // equivalent) — bootstrap() itself throws synchronously once the
        // client side has observed the closure, so this must be a closure
        // (not a pre-evaluated Future) for `throwsA` to catch that.
        expect(
          () => client.bootstrap(_RawCapabilityFactory()).dispatch(0, 0, _emptyParams),
          throwsA(isA<RpcException>()),
        );

        await client.close();
      },
    );
  });
}
