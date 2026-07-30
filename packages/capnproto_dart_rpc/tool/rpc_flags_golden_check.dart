// Golden-test helper for `Return.releaseParamCaps`/`Return.noFinishNeeded`
// (see rpc.capnp) against the real `capnp` CLI — run via
// ci/run-tests.sh, not `dart test` (it needs the `capnp` CLI on PATH,
// which the plain `dart test` CI job does not install).
//
// Usage:
//   dart run tool/rpc_flags_golden_check.dart encode <results|exception> <releaseParamCaps> <noFinishNeeded> <outFile>
//   dart run tool/rpc_flags_golden_check.dart decode <inFile>
//
// `encode` builds a minimal Return(results) or Return(exception) message
// with the given flags and writes its raw bytes to <outFile>, for the
// official `capnp decode` to read back. `decode` parses a Return message
// from <inFile> — typically produced by `capnp encode` from a hand-written
// literal, either variant — and prints the flags this library's own parser
// recovered from it, for the caller to compare against what it asked
// `capnp encode` to set. The flags live outside the results/exception union,
// so `decode` doesn't need to know which variant it's reading.
import 'dart:io';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_proto.dart';

// 16-byte message: single segment (1 word), null root pointer — the
// smallest legal Cap'n Proto message, used as Return.results.content here
// since these golden cases are only about the envelope-level flag bits, not
// the results payload itself.
final _emptyResultBytes = Uint8List.fromList([
  0, 0, 0, 0, 1, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, //
]);

void main(List<String> args) {
  switch (args.first) {
    case 'encode':
      final kind = args[1];
      final releaseParamCaps = args[2] == 'true';
      final noFinishNeeded = args[3] == 'true';
      final outFile = args[4];
      final bytes = switch (kind) {
        'results' => buildReturnResultsMessageFromReader(
          answerId: 5,
          resultsRoot: MessageReader.deserialize(_emptyResultBytes).getRootRaw(),
          releaseParamCaps: releaseParamCaps,
          noFinishNeeded: noFinishNeeded,
        ),
        'exception' => buildReturnExceptionMessage(
          answerId: 5,
          reason: 'golden-test-exception',
          releaseParamCaps: releaseParamCaps,
          noFinishNeeded: noFinishNeeded,
        ),
        _ => throw ArgumentError('unknown encode kind: $kind'),
      };
      File(outFile).writeAsBytesSync(bytes);
    case 'decode':
      final bytes = File(args[1]).readAsBytesSync();
      final msg = parseRpcMessage(bytes);
      print(
        'releaseParamCaps=${msg.returnReleaseParamCaps} '
        'noFinishNeeded=${msg.returnNoFinishNeeded}',
      );
    default:
      stderr.writeln('unknown mode: ${args.first}');
      exit(1);
  }
}
