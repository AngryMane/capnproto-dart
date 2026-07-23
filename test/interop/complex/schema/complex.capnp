@0xd8f8e0f9b6a4c371;

annotation testTag(*) :Text;
annotation numericTag(*) :UInt64;

$testTag("complex-interoperability-schema");

const defaultGreeting :Text = "hello from complex.capnp";
const defaultBlob :Data = 0x"00010203 7f80feff";
const defaultSigned :Int64 = -9223372036854775807;
const defaultUnsigned :UInt64 = 18446744073709551615;
const defaultFloat :Float64 = 3.141592653589793;

enum Color $testTag("enum") {
  red @0;
  green @1;
  blue @2;
  transparent @3;
}

enum Status {
  unknown @0;
  starting @1;
  running @2;
  stopping @3;
  stopped @4;
  failed @5;
}

struct Empty {
}

struct Tiny {
  flag @0 :Bool;
}

struct AllScalars $testTag("all-scalars") {
  nothing @0 :Void;
  boolean @1 :Bool = true;

  int8Value @2 :Int8 = -8;
  int16Value @3 :Int16 = -1600;
  int32Value @4 :Int32 = -320000;
  int64Value @5 :Int64 = -6400000000;

  uint8Value @6 :UInt8 = 8;
  uint16Value @7 :UInt16 = 1600;
  uint32Value @8 :UInt32 = 320000;
  uint64Value @9 :UInt64 = 6400000000;

  float32Value @10 :Float32 = 1.25;
  float64Value @11 :Float64 = -2.5;

  textValue @12 :Text = .defaultGreeting;
  dataValue @13 :Data = .defaultBlob;
  color @14 :Color = green;
}

struct Timestamp {
  seconds @0 :Int64;
  nanoseconds @1 :UInt32;
}

struct Identifier {
  union {
    numeric @0 :UInt64;
    textual @1 :Text;
    binary @2 :Data;
    absent @3 :Void;
  }
}

struct Address {
  country @0 :Text;
  postalCode @1 :Text;
  city @2 :Text;
  street @3 :Text;
  building @4 :Text;
}

struct Person $testTag("nested-types") {
  id @0 :Identifier;
  name @1 :Text;
  email @2 :Text;
  status @3 :Status = unknown;
  favoriteColor @4 :Color = transparent;
  createdAt @5 :Timestamp;

  contact :union {
    noContact @6 :Void;

    phone :group {
      countryCode @7 :UInt16;
      subscriberNumber @8 :Text;
      extension @9 :Text;
    }

    postal :group {
      address @10 :Address;
      attention @11 :Text;
    }

    online :group {
      service @12 :Text;
      account @13 :Text;
    }
  }

  tags @14 :List(Text);
  attributes @15 :List(KeyValue(Text, Text));

  struct Employment {
    employer @0 :Text;
    title @1 :Text;
    since @2 :Timestamp;
    union {
      active @3 :Void;
      endedAt @4 :Timestamp;
    }
  }

  employments @16 :List(Employment);

  enum Relationship {
    parent @0;
    child @1;
    sibling @2;
    spouse @3;
    friend @4;
    colleague @5;
    other @6;
  }

  struct RelatedPerson {
    person @0 :Person;
    relationship @1 :Relationship;
  }

  related @17 :List(RelatedPerson);
}

struct KeyValue(Key, Value) {
  key @0 :Key;
  value @1 :Value;
}

struct Optional(Value) {
  union {
    none @0 :Void;
    some @1 :Value;
  }
}

struct Result(Value, Error) {
  union {
    ok @0 :Value;
    err @1 :Error;
  }
}

struct Tree(NodeValue) {
  value @0 :NodeValue;
  children @1 :List(Tree(NodeValue));
}

struct Matrix {
  rows @0 :List(List(Float64));
}

struct AllLists {
  voids @0 :List(Void);
  bools @1 :List(Bool);

  int8s @2 :List(Int8);
  int16s @3 :List(Int16);
  int32s @4 :List(Int32);
  int64s @5 :List(Int64);

  uint8s @6 :List(UInt8);
  uint16s @7 :List(UInt16);
  uint32s @8 :List(UInt32);
  uint64s @9 :List(UInt64);

  float32s @10 :List(Float32);
  float64s @11 :List(Float64);

  texts @12 :List(Text);
  blobs @13 :List(Data);
  colors @14 :List(Color);
  people @15 :List(Person);
  matrices @16 :List(List(List(Int32)));
}

struct NamedUnion {
  selector @0 :UInt32;

  payload :union {
    empty @1 :Void;
    scalar @2 :Int64;
    text @3 :Text;
    data @4 :Data;
    person @5 :Person;

    coordinates :group {
      x @6 :Float64;
      y @7 :Float64;
      z @8 :Float64;
    }

    rectangle :group {
      left @9 :Float32;
      top @10 :Float32;
      right @11 :Float32;
      bottom @12 :Float32;
    }
  }
}

struct DynamicEnvelope {
  typeName @0 :Text;
  payload @1 :AnyPointer;
  metadata @2 :List(KeyValue(Text, Text));
}

interface Observer(Event) {
  onNext @0 (sequence :UInt64, event :Event) -> ();
  onError @1 (code :UInt32, message :Text, detail :AnyPointer) -> ();
  onComplete @2 () -> ();
}

interface Subscription {
  cancel @0 () -> (wasActive :Bool);
  getId @1 () -> (id :UInt64);
}

interface Readable(Value) {
  read @0 () -> (value :Value, revision :UInt64);
}

interface Writable(Value) {
  write @0 (value :Value, expectedRevision :UInt64 = 0)
      -> (newRevision :UInt64);
}

interface ReadWrite(Value) extends(Readable(Value), Writable(Value)) {
  compareAndSwap @0 (
      expected :Value,
      replacement :Value
  ) -> (
      swapped :Bool,
      actual :Value,
      revision :UInt64
  );
}

struct CursorResult(Value) {
  union {
    done @0 :Void;
    value @1 :Value;
  }
}

interface Cursor(Value) {
  next @0 () -> (result :CursorResult(Value));
}

interface Repository(Key, Value) {
  get @0 (key :Key) -> (result :Optional(Value), revision :UInt64);

  put @1 (
    key :Key,
    value :Value,
    expectedRevision :UInt64 = 0
  ) -> (
    previous :Optional(Value),
    newRevision :UInt64
  );

  remove @2 (
    key :Key,
    expectedRevision :UInt64 = 0
  ) -> (
    removed :Optional(Value),
    newRevision :UInt64
  );

  list @3 () -> (entries :List(KeyValue(Key, Value)));

  openCursor @4 () -> (cursor :Cursor(KeyValue(Key, Value)));

  watch @5 (
    observer :Observer(Change)
  ) -> (
    subscription :Subscription
  );

  struct Change {
    key @0 :Key;
    revision @1 :UInt64;
    # For updated changes only: the value before the update.
    previousValue @5 :Optional(Value);

    union {
      inserted @2 :Value;
      updated @3 :Value;
      removed @4 :Void;
    }
  }
}

interface ByteSink {
  write @0 (chunk :Data) -> stream;
  finish @1 () -> (byteCount :UInt64, checksum :Data);
  abort @2 (reason :Text) -> ();
}

interface ByteSource {
  pumpTo @0 (sink :ByteSink, chunkSize :UInt32 = 65536)
      -> (byteCount :UInt64);
}

interface CapabilityFactory {
  newCell @0 [Value] (initialValue :Value)
      -> (cell :ReadWrite(Value));

  newEmptyCell @1 [Value] ()
      -> (cell :ReadWrite(Value));

  newRepository @2 [Key, Value] ()
      -> (repository :Repository(Key, Value));

  echoCapability @3 [Cap] (capability :Cap)
      -> (sameCapability :Cap);

  getUntyped @4 (name :Text)
      -> (value :AnyPointer);
}

interface Parent {
  getName @0 () -> (name :Text);
}

interface Left extends(Parent) {
  left @0 (value :Int32) -> (result :Int32);
}

interface Right extends(Parent) {
  right @0 (value :Int32) -> (result :Int32);
}

interface Diamond extends(Left, Right) {
  both @0 (leftValue :Int32, rightValue :Int32)
      -> (sum :Int64);
}

interface PipelineTarget {
  getChild @0 (name :Text) -> (child :PipelineTarget);
  getRepository @1 ()
      -> (repository :Repository(Text, Person));
  ping @2 (payload :Data) -> (payload :Data);
}

struct CapabilityBundle {
  primary @0 :PipelineTarget;
  optionalObserver @1 :Optional(Observer(Person));
  targets @2 :List(PipelineTarget);
  repositories @3 :List(Repository(Text, Person));
}

struct ComplexRequest {
  requestId @0 :Identifier;
  timestamp @1 :Timestamp;
  scalars @2 :AllScalars;
  lists @3 :AllLists;
  person @4 :Person;
  tree @5 :Tree(Person);
  matrix @6 :Matrix;
  choice @7 :NamedUnion;
  dynamic @8 :DynamicEnvelope;
  capabilities @9 :CapabilityBundle;
  flags @10 :List(Bool);
  opaqueBytes @11 :Data;
}

struct ComplexResponse {
  requestId @0 :Identifier;
  accepted @1 :Bool;
  status @2 :Status;
  message @3 :Text;
  echoed @4 :ComplexRequest;
  result @5 :Result(Person, ErrorInfo);
  serverCapability @6 :PipelineTarget;
  extra @7 :AnyPointer;
}

struct ErrorInfo {
  code @0 :UInt32;
  category @1 :Text;
  message @2 :Text;
  retryable @3 :Bool;
  details @4 :List(KeyValue(Text, Text));
  cause @5 :Optional(ErrorInfo);
}

interface ComplexTestService $testTag("rpc-root") {
  echo @0 (request :ComplexRequest)
      -> (response :ComplexResponse);

  echoScalars @1 (value :AllScalars)
      -> (value :AllScalars);

  echoLists @2 (value :AllLists)
      -> (value :AllLists);

  echoUnion @3 (value :NamedUnion)
      -> (value :NamedUnion);

  echoAnyPointer @4 [Value] (value :Value)
      -> (value :Value);

  exchangeCapabilities @5 (bundle :CapabilityBundle)
      -> (bundle :CapabilityBundle);

  callObserver @6 (
    observer :Observer(Person),
    events :List(Person)
  ) -> (
    delivered :UInt32
  );

  makePipeline @7 (depth :UInt32)
      -> (target :PipelineTarget);

  openUpload @8 (
    expectedSize :UInt64,
    expectedChecksum :Data
  ) -> (
    sink :ByteSink
  );

  openDownload @9 (
    resourceId :Identifier
  ) -> (
    source :ByteSource,
    metadata :List(KeyValue(Text, Text))
  );

  getRepository @10 ()
      -> (repository :Repository(Text, Person));

  getFactory @11 ()
      -> (factory :CapabilityFactory);

  useDiamond @12 (diamond :Diamond, value :Int32)
      -> (result :Int64);

  failIntentionally @13 (
    code :UInt32,
    message :Text
  ) -> ();

  shutdown @14 () -> ();

  probePipelineTarget @15 (
    target :PipelineTarget,
    payload :Data
  ) -> (
    payload :Data
  );

  makePromisedPipeline @16 (
    delayMs :UInt32
  ) -> (
    target :PipelineTarget
  );

  echoPipelineTargetLater @17 (
    target :PipelineTarget,
    delayMs :UInt32
  ) -> (
    target :PipelineTarget
  );
}
