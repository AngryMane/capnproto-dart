import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';

Future<void> main() async {
  final connection = await RpcSystem.connect(
    Uri.parse('tcp://127.0.0.1:12345'),
  );
  await connection.close();
}
