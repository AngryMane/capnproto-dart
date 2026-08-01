import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:test/test.dart';

void main() {
  group('public API', () {
    test('exposes RpcConnection from the package barrel', () {
      final Future<RpcConnection> Function(Uri) connect = RpcSystem.connect;
      expect(connect, isA<Function>());
    });

    test('can resolve RpcConnection from the package barrel without runtime access', () {
      RpcConnection? connection;
      expect(connection, isNull);
    });
  });
}
