# Use Cases

## Actor

**Flutter/Dart application developer** — a developer building Flutter or Dart applications who wants to use Cap'n Proto for serialization or RPC without relying on FFI.

---

## Overall Flow

```
Define .capnp schema → Generate Dart code → Integrate into app → Serialize / Deserialize / RPC
```

---

## UC-1: Generate Dart Code from Schema

**Summary**: The developer generates Dart source code from a `.capnp` schema file using the code generator.

**Preconditions**:
- A `.capnp` schema file is available.
- The code generator tool is installed.

**Main Flow**:
1. Developer writes or obtains a `.capnp` schema file.
2. Developer runs the code generator tool against the schema file.
3. The tool outputs Dart source files corresponding to the schema types.
4. Developer adds the generated files to their Dart/Flutter project.

**Alternative Flow**:
- If the schema contains syntax errors, the tool reports an error and exits without generating code.

---

## UC-2: Serialize a Cap'n Proto Message

**Summary**: The developer serializes a Dart object into Cap'n Proto binary format.

**Preconditions**:
- Dart code has been generated from the schema (UC-1).
- The generated code is integrated into the project.

**Main Flow**:
1. Developer instantiates a generated Dart class and sets its fields.
2. Developer calls the serialize method to encode the object into binary data.
3. The binary data is ready to be written to a file, sent over a network, or passed to another system.

**Alternative Flow**:
- If required fields are missing or values are out of range, an error is returned before serialization.

---

## UC-3: Deserialize a Cap'n Proto Message

**Summary**: The developer decodes Cap'n Proto binary data back into a Dart object.

**Preconditions**:
- Binary data encoded in Cap'n Proto format is available.
- Dart code has been generated from the matching schema (UC-1).

**Main Flow**:
1. Developer passes binary data to the deserialize method of the generated Dart class.
2. The library decodes the binary data and returns a populated Dart object.
3. Developer accesses the fields of the Dart object as needed.

**Alternative Flow**:
- If the binary data is malformed or does not match the schema, an error is returned.

---

## UC-4: Perform RPC over a Network

**Summary**: The developer uses Cap'n Proto RPC to call remote methods between a Dart client and a server.

**Preconditions**:
- A `.capnp` schema file defining interfaces and methods is available.
- Dart code has been generated from the schema (UC-1).
- A network connection between client and server is established.

**Main Flow**:
1. Developer defines RPC interfaces in the `.capnp` schema.
2. Generated Dart code provides client stubs and server skeletons.
3. Server implements the interface and starts listening.
4. Client connects to the server and calls remote methods using the generated stubs.
5. The library handles serialization, transmission, and deserialization of RPC messages transparently.

**Alternative Flow**:
- If the connection is lost during an RPC call, an error is returned to the caller.
- If the server returns an error, it is propagated to the client as a Dart exception.
