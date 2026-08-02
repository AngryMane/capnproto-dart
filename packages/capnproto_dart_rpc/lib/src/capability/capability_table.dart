import 'dart:collection';

import 'capability.dart' show Capability;

// ---------------------------------------------------------------------------
// CapabilityTableBuilder: write-time capability accumulator.
//
// Generated `setXxxTyped(cap, capTable)` builder helpers (for a struct field
// whose type is an Interface or a List(Interface)) append to this instead of
// managing the outgoing capability table's indices by hand — a plain
// `List<Object?>` invites accidental corruption (clearing it, inserting a
// non-capability, reordering already-assigned entries) that would silently
// desync a builder's wire-level `CapabilityPointer.capabilityIndex` values
// from the accumulator's actual contents. One instance is shared by every
// `setXxxTyped` call reachable from a single generated client method's
// `build` callback (see the two-parameter `build` signature generated for a
// method whose params reach a capability through a nested struct/group/
// List(Interface) field), and its final `capabilities` is passed as that
// call's `paramsCapabilities`.
// ---------------------------------------------------------------------------

final class CapabilityTableBuilder {
  final List<Capability> _capabilities = [];

  /// Adds [capability] to the table and returns the wire-level cap-table
  /// index it was assigned — the value to write into the corresponding
  /// `CapabilityPointer` slot (e.g. via `setCapabilityField`).
  int add(Capability capability) {
    _capabilities.add(capability);
    return _capabilities.length - 1;
  }

  /// The accumulated capabilities in wire-table order, i.e. index `i` here
  /// is exactly what an earlier `add` call returning `i` referred to.
  ///
  /// A live, read-only *view* over the still-growing underlying list —
  /// deliberately not [List.unmodifiable] (a snapshot/copy): this getter is
  /// evaluated as part of a generated client method's `dispatchBuilding(...,
  /// paramsCapabilities: capTable.capabilities)` call, i.e. *before* the
  /// `build` callback that populates the table has run (Dart evaluates
  /// named-argument expressions left to right before the call itself, and
  /// `build` only runs inside `dispatchBuilding`'s body). A snapshot taken
  /// at that point would always be empty; `dispatchBuilding`'s contract is
  /// specifically that it only reads `paramsCapabilities` after `build`
  /// returns, so it needs the live reference.
  List<Capability> get capabilities => UnmodifiableListView(_capabilities);
}
