/// Cap'n Proto RPC Level 1 support for Dart.
library;

// Re-exports capnproto_dart in full so that generated .capnp.dart files only
// need a single import when the schema contains interfaces.
export 'package:capnproto_dart/capnproto_dart.dart';

// ---------------------------------------------------------------------------
// Client application API
// ---------------------------------------------------------------------------

export 'src/capability/capability.dart'
    show
        CapCall,
        Capability,
        DeferredCapability,
        DispatchContext,
        DispatchResult,
        NullCapability,
        PipelinedCapability,
        requireCapabilityFromResult,
        vendCapabilityHandle;
export 'src/capability/capability_any_pointer_codec.dart';
export 'src/capability/capability_factory.dart';
export 'src/rpc/flow_controller.dart';
export 'src/rpc/rpc_exception.dart';
export 'src/rpc/rpc_server.dart';
export 'src/rpc/rpc_system.dart';
export 'src/rpc/two_party_connection.dart' show RpcConnection;
