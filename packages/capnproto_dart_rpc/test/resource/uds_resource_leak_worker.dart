import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:capnproto_dart_rpc/src/rpc/two_party_connection.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../../benchmark/echo_rpc_benchmark_support.dart';

const _rounds = 10;
const _callsPerRound = 1000;
const _warmupRounds = 2;
const _maxRssGrowth = 32 * 1024 * 1024;
const _maxHeapGrowth = 8 * 1024 * 1024;
const _returnCapabilityMethod = 1;
const _acceptCapabilityMethod = 2;

final class _ComplexServer extends Capability {
  final EchoServer child;
  late final CapabilityLease _childOwner;

  _ComplexServer() : child = EchoServer() {
    _childOwner = acquireCapabilityLease(child);
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == echoMethodId) {
      return child.dispatch(interfaceId, methodId, params);
    }
    if (methodId == _returnCapabilityMethod) {
      final message = MessageBuilder();
      final root = message.initRoot(TextParamFactory());
      root.setCapabilityField(0, 0);
      return DispatchResult(
        payload: RpcPayload.fromBuilder(root),
        caps: [acquireCapabilityLease(child)],
      );
    }
    if (methodId == _acceptCapabilityMethod) {
      final root = params.getTyped(TextParamFactory());
      if (root.getCapabilityField(0) != 0 || paramsCapabilities.isEmpty) {
        throw StateError('capability parameter was not transferred');
      }
      try {
        final result = await paramsCapabilities.single.dispatchWithParamsBuilder(
          echoInterfaceId,
          echoMethodId,
          (pointer) => pointer
              .initStruct(TextParamFactory())
              .setTextField(0, 'callback'),
        );
        if (parseEchoResult(result.payload) != 'callback') {
          throw StateError('capability callback returned an invalid result');
        }
      } finally {
        await paramsCapabilities.single.dispose();
      }
      return DispatchResult.empty;
    }
    throw StateError('unknown method $methodId');
  }

  @override
  Future<void> dispose() => _childOwner.dispose();
}

final class _SocketSink implements StreamSink<Uint8List> {
  final Socket socket;
  _SocketSink(this.socket);

  @override
  void add(Uint8List data) => socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<Uint8List> stream) => socket.addStream(stream);
  @override
  Future<void> close() => socket.close();
  @override
  Future<void> get done => socket.done;
}

final class _UdsFixture {
  final String socketPath;
  final ServerSocket listener;
  final StreamSubscription<Socket> listenerSubscription;
  final TwoPartyRpcConnection clientConnection;
  final TwoPartyRpcConnection serverConnection;
  final EchoClient client;

  _UdsFixture(
    this.socketPath,
    this.listener,
    this.listenerSubscription,
    this.clientConnection,
    this.serverConnection,
    this.client,
  );

  static var _nextId = 0;

  static Future<_UdsFixture> open() async {
    final socketPath =
        '${Directory.systemTemp.path}/cpdr_leak_${pid}_${_nextId++}.sock';
    final socketFile = File(socketPath);
    if (await socketFile.exists()) await socketFile.delete();

    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    final listener = await ServerSocket.bind(address, 0);
    final serverReady = Completer<TwoPartyRpcConnection>();
    late final StreamSubscription<Socket> listenerSubscription;
    listenerSubscription = listener.listen((socket) {
      if (!serverReady.isCompleted) {
        serverReady.complete(
          TwoPartyRpcConnection.server(
            incoming: socket,
            outgoing: _SocketSink(socket),
            bootstrap: _ComplexServer(),
          ),
        );
      } else {
        socket.destroy();
      }
    });

    final clientSocket = await Socket.connect(address, 0);
    final clientConnection = TwoPartyRpcConnection.client(
      incoming: clientSocket,
      outgoing: _SocketSink(clientSocket),
    );
    final serverConnection = await serverReady.future;
    final client = clientConnection.bootstrap(EchoClientFactory());
    return _UdsFixture(
      socketPath,
      listener,
      listenerSubscription,
      clientConnection,
      serverConnection,
      client,
    );
  }

  Future<void> close() async {
    await client.dispose();
    await clientConnection.close();
    await serverConnection.close();
    await listenerSubscription.cancel();
    await listener.close();
    final socketFile = File(socketPath);
    if (await socketFile.exists()) await socketFile.delete();
  }
}

Future<(VmService, String)> _connectToSelf() async {
  final info = await Service.getInfo();
  final websocketUri = info.serverWebSocketUri;
  if (websocketUri == null) {
    throw StateError('VM Service is required for the resource leak test');
  }
  final service = await vmServiceConnectUri(websocketUri.toString());
  final vm = await service.getVM();
  final isolates = vm.isolates ?? const <IsolateRef>[];
  if (isolates.length != 1 || isolates.single.id == null) {
    throw StateError('expected exactly one application isolate: $isolates');
  }
  return (service, isolates.single.id!);
}

Future<int> _collectAndReadHeap(VmService service, String isolateId) async {
  await service.getAllocationProfile(isolateId, gc: true);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final usage = await service.getMemoryUsage(isolateId);
  return usage.heapUsage ?? -1;
}

int _median(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

RpcPayload _payload(String text) {
  final message = MessageBuilder();
  final root = message.initRoot(TextParamFactory());
  root.setTextField(0, text);
  return RpcPayload.fromBuilder(root);
}

Future<String> _echoThrough(Capability capability, String text) async {
  final result = await capability.dispatchWithParamsBuilder(
    echoInterfaceId,
    echoMethodId,
    (pointer) => pointer.initStruct(TextParamFactory()).setTextField(0, text),
  );
  return parseEchoResult(result.payload) ?? '';
}

Future<void> _passCapability(_UdsFixture fixture) async {
  final callback = EchoServer();
  await fixture.client.cap.dispatchWithParamsBuilder(
    echoInterfaceId,
    _acceptCapabilityMethod,
    (pointer) =>
        pointer.initStruct(TextParamFactory()).setCapabilityField(0, 0),
    paramsCapabilities: [callback],
  );
}

Future<(Capability, List<Capability>)> _pipelineCapability(
  _UdsFixture fixture,
) async {
  final parent = fixture.client.cap.dispatchForPipelining(
    echoInterfaceId,
    _returnCapabilityMethod,
    _payload('pipeline-parent'),
  );
  final pipelined = parent.pipelinedCapability(0);
  final reply = await _echoThrough(pipelined, 'pipelined-call');
  if (reply != 'pipelined-call') {
    throw StateError('pipelined call returned an invalid result');
  }
  final parentResult = await parent.result;
  return (pipelined, parentResult.caps);
}

Future<void> _streamCall(_UdsFixture fixture, int sequence) =>
    fixture.client.cap.dispatchStreaming(
      echoInterfaceId,
      echoMethodId,
      _payload('stream=$sequence'),
    );

Future<List<WeakReference<Object>>> _createDisposedWeakReferences() async {
  final references = <WeakReference<Object>>[];
  for (var cycle = 0; cycle < 5; cycle++) {
    final fixture = await _UdsFixture.open();
    final callback = EchoServer();
    await fixture.client.cap.dispatchWithParamsBuilder(
      echoInterfaceId,
      _acceptCapabilityMethod,
      (pointer) =>
          pointer.initStruct(TextParamFactory()).setCapabilityField(0, 0),
      paramsCapabilities: [callback],
    );
    final (pipelined, returnedCaps) = await _pipelineCapability(fixture);
    references.addAll([
      WeakReference<Object>(callback),
      WeakReference<Object>(pipelined),
      for (final cap in returnedCaps) WeakReference<Object>(cap),
      WeakReference<Object>(fixture.client),
      WeakReference<Object>(fixture.clientConnection),
      WeakReference<Object>(fixture.serverConnection),
    ]);
    await pipelined.dispose();
    for (final cap in returnedCaps) {
      await cap.dispose();
    }
    await fixture.close();
  }
  return references;
}

Future<bool> _waitUntilCollected(
  List<WeakReference<Object>> references,
  VmService service,
  String isolateId,
) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await _collectAndReadHeap(service, isolateId);
    if (references.every((reference) => reference.target == null)) return true;
    Uint8List(2 * 1024 * 1024);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return false;
}

Future<void> main() async {
  if (Platform.isWindows) {
    throw UnsupportedError('Unix domain sockets are unavailable on Windows');
  }

  final (service, isolateId) = await _connectToSelf();
  final fixture = await _UdsFixture.open();
  final rssSamples = <int>[];
  final heapSamples = <int>[];

  try {
    for (var round = 0; round < _rounds + _warmupRounds; round++) {
      for (var call = 0; call < _callsPerRound; call++) {
        switch (call % 10) {
          case 0:
            await _passCapability(fixture);
          case 1:
            final (pipelined, returnedCaps) = await _pipelineCapability(
              fixture,
            );
            await pipelined.dispose();
            for (final cap in returnedCaps) {
              await cap.dispose();
            }
          case 2:
          case 3:
            await _streamCall(fixture, round * _callsPerRound + call);
          default:
            final reply = await fixture.client.echo('round=$round call=$call');
            if (!reply.startsWith('round=')) {
              throw StateError('unexpected RPC response: $reply');
            }
        }
      }
      await fixture.client.echo('round-drain=$round');
      final heap = await _collectAndReadHeap(service, isolateId);
      if (round >= _warmupRounds) {
        heapSamples.add(heap);
        rssSamples.add(ProcessInfo.currentRss);
      }
    }
  } finally {
    await fixture.close();
  }

  final earlyRss = _median(rssSamples.take(3).toList());
  final lateRss = _median(rssSamples.skip(rssSamples.length - 3).toList());
  final earlyHeap = _median(heapSamples.take(3).toList());
  final lateHeap = _median(heapSamples.skip(heapSamples.length - 3).toList());
  final rssGrowth = lateRss - earlyRss;
  final heapGrowth = lateHeap - earlyHeap;

  final weakReferences = await _createDisposedWeakReferences();
  final weakReferencesCollected = await _waitUntilCollected(
    weakReferences,
    service,
    isolateId,
  );
  await service.dispose();

  final result = <String, Object>{
    'transport': 'uds',
    'operations': _rounds * _callsPerRound,
    'rpcCalls': _rounds * (_callsPerRound + 201),
    'capabilityTransfers': _rounds * 100,
    'pipelinedCalls': _rounds * 100,
    'streamingCalls': _rounds * 200,
    'connectionCycles': 5,
    'rssSamples': rssSamples,
    'heapSamples': heapSamples,
    'rssGrowth': rssGrowth,
    'heapGrowth': heapGrowth,
    'weakReferencesCollected': weakReferencesCollected,
  };
  stdout.writeln(jsonEncode(result));

  if (rssGrowth > _maxRssGrowth) {
    throw StateError(
      'RSS grew by $rssGrowth bytes (limit: $_maxRssGrowth): $rssSamples',
    );
  }
  if (heapGrowth > _maxHeapGrowth) {
    throw StateError(
      'heap grew by $heapGrowth bytes (limit: $_maxHeapGrowth): $heapSamples',
    );
  }
  if (!weakReferencesCollected) {
    throw StateError('disposed RPC objects remained strongly reachable');
  }
}
