import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:test/test.dart';

void main() {
  group('public API', () {
    test('exposes RpcConnection from the package barrel', () {
      Future<RpcConnection> connect(Uri address) => RpcSystem.connect(address);
      expect(connect(Uri.parse('tcp://127.0.0.1:0')), isA<Future<RpcConnection>>());
    });
  });
}
