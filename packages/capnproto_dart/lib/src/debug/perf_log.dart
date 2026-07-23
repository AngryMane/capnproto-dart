import 'dart:developer' as developer;

/// Whether debug-only performance instrumentation is active for this build.
///
/// `true` for `dart run` (JIT/debug) and profile builds (`dart compile exe
/// -Ddart.vm.profile=true -Ddart.vm.product=false ...`, which is how
/// Flutter's own tooling invokes the AOT compiler for `flutter run
/// --profile`/`flutter build --profile`); `false` for release builds
/// (`dart compile exe`'s default already sets `dart.vm.product=true`, as
/// does an explicit `-Ddart.vm.product=true`).
///
/// Mirrors Flutter's `kDebugMode`/`kProfileMode`/`kReleaseMode` convention
/// (`kDebugLoggingEnabled == kDebugMode || kProfileMode == !kReleaseMode`)
/// without depending on `package:flutter` — this package has no Flutter
/// dependency and must also work from a plain Dart process, and Flutter's
/// build tool sets these same `dart.vm.*` environment defines regardless of
/// which package reads them, so this stays correct when embedded in a
/// Flutter app too.
///
/// Verified empirically (not just from documentation) against the real
/// `dart` SDK: `dart run` reports `dart.vm.product=false`; plain `dart
/// compile exe` reports `dart.vm.product=true` even with no explicit
/// `-D` flags; `-Ddart.vm.profile=true -Ddart.vm.product=false` reproduces
/// Flutter's profile-mode combination.
///
/// Every call site using this must gate the *entire* block behind
/// `if (kDebugLoggingEnabled) { ... }` (not just pass it as an argument to
/// a logging function) — [bool.fromEnvironment] is a compile-time constant,
/// so a release AOT build's compiler dead-code-eliminates a block guarded
/// this way in its entirety, including any argument/duration computation
/// inside it. [timePerf] already does this internally.
const bool kDebugLoggingEnabled = !bool.fromEnvironment(
  'dart.vm.product',
  defaultValue: false,
);

/// Runs [body], recording it as a named synchronous span on
/// `dart:developer`'s [developer.Timeline] — visible as a labeled block in
/// DevTools' Timeline view (or any other tool attached via the VM service
/// protocol) for exactly the kind of "which step took how long" comparison
/// against another implementation this is meant to support.
///
/// A plain passthrough (`return body();`, no [developer.Timeline] call at
/// all) in release builds — see [kDebugLoggingEnabled]. [Timeline] entries
/// are lightweight even when nothing is attached to observe them, but
/// running many thousands of them in a hot loop (e.g. once per field write)
/// is still meant for occasional profiling runs, not for wrapping every
/// call in code that ships to users.
T timePerf<T>(String name, T Function() body) {
  if (!kDebugLoggingEnabled) return body();
  return developer.Timeline.timeSync(name, body);
}
