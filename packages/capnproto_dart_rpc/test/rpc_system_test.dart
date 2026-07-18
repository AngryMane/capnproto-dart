import 'dart:async';
import 'dart:io';
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

    test(
      'a malformed/aborted connection does not surface as an unhandled '
      'top-level error, and does not destabilize later connections',
      () async {
        // Regression test: RpcSystem.serve's per-connection tracking (added
        // for the fix above) used `conn.done.whenComplete(...)` to remove a
        // connection from the tracked set once it closes. TwoPartyRpcConnection
        // itself calls `.ignore()` on that same completer before erroring it,
        // specifically so an unobserved `.done` doesn't print as unhandled —
        // but `.whenComplete()` replays the same error onto the *new* future
        // it returns, and that one was left unobserved. A single malformed
        // connection (e.g. a port-liveness probe that sends one byte and
        // disconnects, exactly like the `echo > /dev/tcp/...` idiom used in
        // this repo's own ci/run-tests.sh) was therefore printed as a
        // top-level "Unhandled exception" — which terminates the isolate,
        // breaking every connection accepted afterward too.
        final unhandledErrors = <Object>[];

        await runZonedGuarded(
          () async {
            final server = await RpcSystem.serve(
              Uri.parse('tcp://127.0.0.1:0'),
              NullCapability(),
            );
            addTearDown(server.close);

            // A stray connection that can never form a complete Cap'n Proto
            // message: one byte, then disconnect.
            final probe = await Socket.connect('127.0.0.1', server.port);
            probe.add([10]);
            await probe.flush();
            await probe.close();

            // Give the server a moment to observe and tear down the bad
            // connection.
            await Future<void>.delayed(const Duration(milliseconds: 300));

            // A legitimate client connecting afterward must still work —
            // the process/isolate must not have been brought down by the
            // probe connection's error.
            final client = await RpcSystem.connect(
              Uri.parse('tcp://127.0.0.1:${server.port}'),
            );
            await expectLater(
              client.bootstrap(_RawCapabilityFactory()).dispatch(
                    0,
                    0,
                    _emptyParams,
                  ),
              throwsA(isA<RpcException>()),
            );
            await client.close();
          },
          (error, stackTrace) => unhandledErrors.add(error),
        );

        expect(
          unhandledErrors,
          isEmpty,
          reason:
              'expected no unhandled top-level errors from the malformed '
              'connection, got: $unhandledErrors',
        );
      },
    );
  });
}
