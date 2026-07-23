import 'package:capnproto_dart/capnproto_dart.dart';

void main() {
  final builder = MessageBuilder();
  final bytes = builder.serialize();
  MessageReader.deserialize(bytes);
}
