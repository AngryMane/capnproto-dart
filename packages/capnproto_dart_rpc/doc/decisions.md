# Design Decisions: RPC Runtime (`capnproto_dart_rpc`)

Rationale for choices that shape this package's implementation — the *why*, not the
current file/class layout (see [`internal-design.md`](internal-design.md) for that).
Written in terms of stable concepts rather than private symbol names, so a rename or
refactor in the implementation doesn't make this document wrong.

## Four-table lifecycle model

Capability and call lifecycle is tracked via four logical tables — Questions,
Answers, Exports, Imports — rather than a general-purpose registry. This follows the
Cap'n Proto Level 1 RPC specification's two-party subset directly, so the
implementation's bookkeeping maps onto the protocol's own vocabulary instead of an
abstraction layered on top of it.

## Tail calls: no pipelining past a redirected answer

When a tail call forwards to a capability on the same peer connection, the original
question is answered via `Return.takeFromOtherQuestion` instead of being registered
as a normal completed answer. A consequence of that shortcut is that a caller cannot
pipeline a further call onto that answer — doing so fails with a clear
`RpcException` (see `external-spec.md`) rather than being supported or silently
producing a wrong result. This is a deliberate simplification, not an oversight:
supporting further pipelining would mean tracking redirection chains through the
Answers table instead of a single hop.

## Tail calls: result-capability ownership stays with the original caller

A forwarded tail call's result capabilities are owned by the original local caller,
not by the bookkeeping entry created to correlate the redirect. That entry is
finished without releasing result capabilities, precisely because ownership was
already handed to the caller — finishing it the normal way would release capabilities
the caller still holds.

## Single isolate, no built-in offload

The connection's message loop and all call dispatch — including dispatch into a
locally implemented capability — run on the isolate that created the connection; the
library does not spawn a separate isolate for this. Offloading CPU-heavy work
triggered by an incoming call is left to the capability implementation (e.g. via
`Isolate.run`/`compute` inside its own dispatch method), not provided by the runtime.

## No pluggable transport abstraction

There is no `VatNetwork`-style transport interface. `RpcSystem.connect`/`serve`
hardcode a TCP transport. Applications that need a different transport (e.g.
in-process pipes for testing) construct the two-party connection directly rather
than the library exposing a transport plugin point.

## Errors are never silently swallowed

Every public method surfaces failures as a `CapnpException` subclass
(`RpcException` for this package); nothing is caught and discarded internally. This
matches the shared error-handling strategy described in
[`capnproto_dart`'s internal design](pathname:///capnproto_dart/internal-design#error-handling-strategy).
