import 'package:build/build.dart';

import 'src/capnp_builder.dart';

export 'src/capnp_builder.dart'
    show CapnpBuilder, CapnpCompileException, extractRelativeCapnpImports;

/// Builder factory referenced from `build.yaml`. See [CapnpBuilder].
Builder capnpBuilder(BuilderOptions options) => CapnpBuilder(options);
