// Cap'n Proto "text format" — the human-readable representation used by
// the `capnp encode`/`capnp decode` CLI tools (e.g. `(name = "hi", size =
// 3)`). Implemented generically against [StructSchemaInfo]/[EnumSchemaInfo]
// reflection metadata (see reflection.dart) plus the schema-less
// Dynamic*Reader/Builder API (see any_pointer.dart), so it works for any
// generated struct without needing per-type generated support.
//
// The exact grammar isn't published as a formal spec; the encoder/decoder
// here were built and checked against the reference `capnp` CLI's actual
// input/output (see capnpc-dart and capnproto_dart's test suites) rather
// than derived from a written grammar.
import 'dart:convert';
import 'dart:typed_data';

import '../exception/decode_exception.dart';
import '../layout/any_pointer.dart';
import '../layout/struct_reader.dart';
import '../message/message_builder.dart';
import '../schema/reflection.dart';
import '../wire/pointer.dart' show ListElementSize;

/// Maps a schema node id to its [SchemaInfo] (struct or enum), so
/// [encodeText]/[decodeText] can resolve the nested struct/enum types
/// referenced by field types. Node ids are globally unique, so one registry
/// can cover an entire schema file (or several).
///
/// Build one from your generated file's `xxxSchema` constants:
/// ```dart
/// final registry = schemaRegistryOf([fooSchema, barSchema, colorSchema]);
/// ```
typedef SchemaRegistry = Map<int, SchemaInfo>;

/// Builds a [SchemaRegistry] from a list of `xxxSchema` constants (as
/// exposed by every generated struct/enum, e.g. `FooReader.schema`).
SchemaRegistry schemaRegistryOf(Iterable<SchemaInfo> schemas) => {
  for (final s in schemas) s.id: s,
};

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Renders [reader] as Cap'n Proto text format, e.g. `(name = "hi", size =
/// 3)` — matching `capnp decode --short`'s output (a single line, no space
/// padding inside the parens).
///
/// [registry] must contain the [SchemaInfo] for every struct/enum/group type
/// reachable from [schema] (nested structs, list element types, group
/// bodies) — see [schemaRegistryOf].
///
/// Throws [DecodeException] if the struct (transitively) contains a
/// capability or an untyped `AnyPointer`/generic field with a value set:
/// neither has a text representation (matches [MessageReader.canonicalize]'s
/// precedent of refusing what it can't faithfully represent).
String encodeText(
  StructReader reader,
  StructSchemaInfo schema,
  SchemaRegistry registry,
) {
  final buf = StringBuffer();
  _encodeStructFields(buf, reader, schema, registry);
  return buf.toString();
}

void _encodeStructFields(
  StringBuffer buf,
  StructReader r,
  StructSchemaInfo schema,
  SchemaRegistry registry,
) {
  buf.write('(');
  final sorted = [...schema.fields]
    ..sort((a, b) => a.codeOrder.compareTo(b.codeOrder));
  final activeDisc =
      schema.discriminantCount > 0
          ? r.getUint16Field(schema.discriminantOffset * 2)
          : null;
  var wrote = false;
  for (final field in sorted) {
    if (field.isUnionField && field.discriminantValue != activeDisc) continue;
    final text = _encodeField(r, field, registry);
    if (text == null) continue;
    if (wrote) buf.write(', ');
    buf.write(field.name);
    buf.write(' = ');
    buf.write(text);
    wrote = true;
  }
  buf.write(')');
}

String? _encodeField(
  StructReader r,
  FieldSchemaInfo field,
  SchemaRegistry registry,
) {
  final body = field.body;
  if (body is GroupFieldSchemaInfo) {
    final groupSchema = _requireStructSchema(registry, body.typeId);
    final buf = StringBuffer();
    _encodeStructFields(buf, r, groupSchema, registry);
    return buf.toString();
  }
  final slot = body as SlotFieldSchemaInfo;
  return _encodeValue(r, slot.type, slot.offset, slot.defaultValue, registry);
}

String? _encodeValue(
  StructReader r,
  TypeSchemaInfo type,
  int offset,
  Object? defaultValue,
  SchemaRegistry registry,
) {
  if (type is PrimitiveTypeSchemaInfo) {
    switch (type.name) {
      case 'Void':
        return 'void';
      case 'Bool':
        return r.getBoolField(offset, defaultValue: defaultValue == true)
            ? 'true'
            : 'false';
      case 'Int8':
        return r
            .getInt8Field(offset, defaultValue: (defaultValue as int?) ?? 0)
            .toString();
      case 'Int16':
        return r
            .getInt16Field(
              offset * 2,
              defaultValue: (defaultValue as int?) ?? 0,
            )
            .toString();
      case 'Int32':
        return r
            .getInt32Field(
              offset * 4,
              defaultValue: (defaultValue as int?) ?? 0,
            )
            .toString();
      case 'Int64':
        return r
            .getInt64Field(
              offset * 8,
              defaultValue: (defaultValue as int?) ?? 0,
            )
            .toString();
      case 'UInt8':
        return r
            .getUint8Field(offset, defaultValue: (defaultValue as int?) ?? 0)
            .toString();
      case 'UInt16':
        return r
            .getUint16Field(
              offset * 2,
              defaultValue: (defaultValue as int?) ?? 0,
            )
            .toString();
      case 'UInt32':
        return r
            .getUint32Field(
              offset * 4,
              defaultValue: (defaultValue as int?) ?? 0,
            )
            .toString();
      case 'UInt64':
        return r
            .getUint64Field(
              offset * 8,
              defaultValue: (defaultValue as int?) ?? 0,
            )
            .toString();
      case 'Float32':
        return _formatFloat(
          r.getFloat32Field(
            offset * 4,
            defaultValue: (defaultValue as double?) ?? 0.0,
          ),
        );
      case 'Float64':
        return _formatFloat(
          r.getFloat64Field(
            offset * 8,
            defaultValue: (defaultValue as double?) ?? 0.0,
          ),
        );
      case 'Text':
        final v = r.getTextField(offset, defaultValue: defaultValue as String?);
        return v == null ? null : _quoteText(v);
      case 'Data':
        final v = r.getDataField(
          offset,
          defaultValue: defaultValue as Uint8List?,
        );
        return v == null ? null : _quoteData(v);
    }
    throw DecodeException(
      'unsupported primitive type in text format: ${type.name}',
    );
  }
  if (type is EnumRefTypeSchemaInfo) {
    final raw = r.getUint16Field(
      offset * 2,
      defaultValue: (defaultValue as int?) ?? 0,
    );
    return _enumName(type.typeId, raw, registry);
  }
  // Struct/list/capability/AnyPointer fields are all pointer-typed: a null
  // pointer means "field not set", uniformly omitted from the output the
  // same way capnp's own encoder omits them.
  if (!r.hasPointerField(offset)) return null;
  if (type is StructRefTypeSchemaInfo) {
    final nested = r.getAnyPointerField(offset)!.asDynamicStruct()!;
    final structSchema = _requireStructSchema(registry, type.typeId);
    final buf = StringBuffer();
    _encodeStructFields(buf, nested, structSchema, registry);
    return buf.toString();
  }
  if (type is ListTypeSchemaInfo) {
    final list = r.getAnyPointerField(offset)!.asDynamicList()!;
    return _encodeList(list, type.elementType, registry);
  }
  if (type is InterfaceRefTypeSchemaInfo) {
    throw const DecodeException(
      'capabilities are not representable in text format',
    );
  }
  throw DecodeException(
    'AnyPointer/generic-typed fields are not representable in text format '
    '(field type: $type)',
  );
}

String _encodeList(
  DynamicListReader list,
  TypeSchemaInfo elementType,
  SchemaRegistry registry,
) {
  final buf = StringBuffer('[');
  for (var i = 0; i < list.length; i++) {
    if (i > 0) buf.write(', ');
    buf.write(_encodeListElement(list, i, elementType, registry));
  }
  buf.write(']');
  return buf.toString();
}

String _encodeListElement(
  DynamicListReader list,
  int i,
  TypeSchemaInfo elementType,
  SchemaRegistry registry,
) {
  if (elementType is PrimitiveTypeSchemaInfo) {
    switch (elementType.name) {
      case 'Void':
        return 'void';
      case 'Bool':
        return list.getBool(i) ? 'true' : 'false';
      case 'Int8':
        return list.getInt8(i).toString();
      case 'Int16':
        return list.getInt16(i).toString();
      case 'Int32':
        return list.getInt32(i).toString();
      case 'Int64':
        return list.getInt64(i).toString();
      case 'UInt8':
        return list.getUint8(i).toString();
      case 'UInt16':
        return list.getUint16(i).toString();
      case 'UInt32':
        return list.getUint32(i).toString();
      case 'UInt64':
        return list.getUint64(i).toString();
      case 'Float32':
        return _formatFloat(list.getFloat32(i));
      case 'Float64':
        return _formatFloat(list.getFloat64(i));
      case 'Text':
        final v = list.getText(i);
        return v == null ? 'null' : _quoteText(v);
      case 'Data':
        final v = list.getData(i);
        return v == null ? 'null' : _quoteData(v);
    }
    throw DecodeException(
      'unsupported list element type in text format: ${elementType.name}',
    );
  }
  if (elementType is EnumRefTypeSchemaInfo) {
    return _enumName(elementType.typeId, list.getUint16(i), registry);
  }
  if (elementType is StructRefTypeSchemaInfo) {
    final structSchema = _requireStructSchema(registry, elementType.typeId);
    final buf = StringBuffer();
    _encodeStructFields(buf, list.getStruct(i), structSchema, registry);
    return buf.toString();
  }
  if (elementType is ListTypeSchemaInfo) {
    final inner = list.getList(i);
    if (inner == null) return '[]';
    return _encodeList(inner, elementType.elementType, registry);
  }
  if (elementType is InterfaceRefTypeSchemaInfo) {
    throw const DecodeException(
      'capabilities are not representable in text format',
    );
  }
  throw DecodeException(
    'AnyPointer/generic-typed list elements are not representable in text '
    'format (element type: $elementType)',
  );
}

StructSchemaInfo _requireStructSchema(SchemaRegistry registry, int typeId) {
  final schema = registry[typeId];
  if (schema is! StructSchemaInfo) {
    throw DecodeException(
      'struct type 0x${typeId.toRadixString(16)} not found in schema '
      'registry (pass every reachable struct/enum schema to schemaRegistryOf)',
    );
  }
  return schema;
}

EnumSchemaInfo _requireEnumSchema(SchemaRegistry registry, int typeId) {
  final schema = registry[typeId];
  if (schema is! EnumSchemaInfo) {
    throw DecodeException(
      'enum type 0x${typeId.toRadixString(16)} not found in schema registry '
      '(pass every reachable struct/enum schema to schemaRegistryOf)',
    );
  }
  return schema;
}

/// An enumerant's wire value is its *position* once [EnumSchemaInfo
/// .enumerants] is sorted by [EnumerantSchemaInfo.codeOrder] — mirrors
/// exactly how capnpc-dart itself assigns `enum Foo { a, b, c }` values (see
/// dart_generator.dart's `_writeEnumSchema`/`fooFromUint16`), so this stays
/// correct without re-deriving the rule independently.
List<EnumerantSchemaInfo> _sortedEnumerants(EnumSchemaInfo schema) =>
    [...schema.enumerants]..sort((a, b) => a.codeOrder.compareTo(b.codeOrder));

String _enumName(int typeId, int rawValue, SchemaRegistry registry) {
  final sorted = _sortedEnumerants(_requireEnumSchema(registry, typeId));
  if (rawValue < 0 || rawValue >= sorted.length) {
    // An enumerant added by a newer schema version than this registry knows
    // about. capnp's own text format has no valid syntax for this either —
    // surface the raw ordinal rather than silently misnaming it as some
    // other enumerant.
    return '/* unknown enumerant */ $rawValue';
  }
  return sorted[rawValue].name;
}

String _formatFloat(double v) {
  if (v.isNaN) return 'nan';
  if (v == double.infinity) return 'inf';
  if (v == double.negativeInfinity) return '-inf';
  var s = v.toString();
  // Dart writes `1e+300`; capnp writes `1e300` (no `+`).
  s = s.replaceFirst('e+', 'e');
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return s;
}

String _quoteText(String s) {
  final buf = StringBuffer('"');
  for (final rune in s.runes) {
    _writeEscapedByteOrRune(buf, rune, isRune: true);
  }
  buf.write('"');
  return buf.toString();
}

String _quoteData(Uint8List bytes) {
  final buf = StringBuffer('"');
  for (final b in bytes) {
    _writeEscapedByteOrRune(buf, b, isRune: false);
  }
  buf.write('"');
  return buf.toString();
}

/// Shared quoting rule for both [_quoteText] (Unicode runes — a non-ASCII
/// rune is valid UTF-8 text and passes through as-is, matching capnp) and
/// [_quoteData] (raw bytes — anything outside printable ASCII is escaped,
/// since a byte >= 0x80 isn't a standalone printable character).
void _writeEscapedByteOrRune(
  StringBuffer buf,
  int value, {
  required bool isRune,
}) {
  switch (value) {
    case 0x22:
      buf.write(r'\"');
    case 0x5c:
      buf.write(r'\\');
    case 0x0a:
      buf.write(r'\n');
    case 0x0d:
      buf.write(r'\r');
    case 0x09:
      buf.write(r'\t');
    default:
      if (value >= 0x20 && value < 0x7f) {
        buf.writeCharCode(value);
      } else if (isRune && value >= 0x80) {
        buf.writeCharCode(value);
      } else {
        buf.write('\\${value.toRadixString(8).padLeft(3, '0')}');
      }
  }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Parses [text] (Cap'n Proto text format, e.g. `(name = "hi", size = 3)`)
/// against [schema] and returns a standalone, framed Cap'n Proto message
/// (ready for `MessageReader.deserialize(...).getRoot(fooFactory)`).
///
/// [registry] must contain the [SchemaInfo] for every struct/enum/group type
/// reachable from [schema] — see [schemaRegistryOf].
///
/// Throws [DecodeException] for a syntax error, an unknown field/enumerant
/// name, or a value for a capability/`AnyPointer`/generic-typed field
/// (none of these are representable in text format — see [encodeText]).
Uint8List decodeText(
  String text,
  StructSchemaInfo schema,
  SchemaRegistry registry,
) {
  final tokens = _tokenize(text);
  final parser = _TextParser(tokens, text);
  final value = parser.parseValue();
  parser.expectEnd();
  if (value is! _TextStruct) {
    throw const DecodeException(
      'expected a struct literal `( ... )` at the top level',
    );
  }

  final mb = MessageBuilder();
  final builder = mb.initDynamicRoot(
    dataWords: schema.dataWords,
    pointerWords: schema.pointerWords,
  );
  _materializeStruct(value, builder, schema, registry);
  return mb.serialize();
}

// ---- AST ----

sealed class _TextValue {
  const _TextValue();
}

final class _TextStruct extends _TextValue {
  final Map<String, _TextValue> fields;
  const _TextStruct(this.fields);
}

final class _TextList extends _TextValue {
  final List<_TextValue> items;
  const _TextList(this.items);
}

/// A quoted string literal (`"..."` or `0x"..."`), stored as raw bytes.
/// Interpreted as UTF-8 text or as raw [Uint8List] depending on the target
/// field's type — see `_materializeSlotValue`.
final class _TextBytes extends _TextValue {
  final List<int> bytes;
  const _TextBytes(this.bytes);
}

/// A numeric literal, kept as source text so it can be parsed as an int or
/// a double depending on the target field's type (`123` is valid for
/// either; only the target type disambiguates).
final class _TextNumber extends _TextValue {
  final String raw;
  const _TextNumber(this.raw);
}

/// A bare word: `true`, `false`, `void`, `nan`, `inf`, `-inf`, an enumerant
/// name, or a field name used as a union-member shorthand value (not
/// supported here — capnp's text format always requires `name = value`).
final class _TextIdent extends _TextValue {
  final String name;
  const _TextIdent(this.name);
}

// ---- Tokenizer ----

enum _TokKind {
  lparen,
  rparen,
  lbracket,
  rbracket,
  equals,
  comma,
  ident,
  number,
  string,
  hexString,
  end,
}

class _Tok {
  final _TokKind kind;
  final String text;
  final List<int>? bytes; // for string/hexString
  final int pos;
  const _Tok(this.kind, this.text, this.pos, {this.bytes});
}

List<_Tok> _tokenize(String src) {
  final tokens = <_Tok>[];
  var i = 0;
  final n = src.length;

  while (i < n) {
    final c = src.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) {
      i++;
      continue;
    }
    if (c == 0x23) {
      // # comment to end of line
      while (i < n && src.codeUnitAt(i) != 0x0a) {
        i++;
      }
      continue;
    }
    final start = i;
    switch (c) {
      case 0x28:
        tokens.add(_Tok(_TokKind.lparen, '(', start));
        i++;
        continue;
      case 0x29:
        tokens.add(_Tok(_TokKind.rparen, ')', start));
        i++;
        continue;
      case 0x5b:
        tokens.add(_Tok(_TokKind.lbracket, '[', start));
        i++;
        continue;
      case 0x5d:
        tokens.add(_Tok(_TokKind.rbracket, ']', start));
        i++;
        continue;
      case 0x3d:
        tokens.add(_Tok(_TokKind.equals, '=', start));
        i++;
        continue;
      case 0x2c:
        tokens.add(_Tok(_TokKind.comma, ',', start));
        i++;
        continue;
      case 0x22:
        final bytes = _scanQuoted(src, i + 1, (end) => i = end);
        tokens.add(_Tok(_TokKind.string, '', start, bytes: bytes));
        continue;
    }
    // 0x"..." hex-data literal, or a hex/decimal number starting with `0x`.
    if (c == 0x30 &&
        i + 1 < n &&
        (src.codeUnitAt(i + 1) == 0x78 || src.codeUnitAt(i + 1) == 0x58) &&
        i + 2 < n &&
        src.codeUnitAt(i + 2) == 0x22) {
      final bytes = _scanHexQuoted(src, i + 3, (end) => i = end);
      tokens.add(_Tok(_TokKind.hexString, '', start, bytes: bytes));
      continue;
    }
    if (c == 0x2d || (c >= 0x30 && c <= 0x39)) {
      // Number: optional leading '-', then digits/hex/float syntax.
      var j = i + 1;
      if (c == 0x2d) {
        // `-inf` is the only non-numeric thing that can follow a minus sign.
        if (j + 2 < n &&
            src.substring(j, j + 3) == 'inf' &&
            (j + 3 >= n || !_isIdentChar(src.codeUnitAt(j + 3)))) {
          tokens.add(_Tok(_TokKind.ident, '-inf', start));
          i = j + 3;
          continue;
        }
      }
      while (j < n && _isNumberChar(src.codeUnitAt(j))) {
        j++;
      }
      tokens.add(_Tok(_TokKind.number, src.substring(start, j), start));
      i = j;
      continue;
    }
    if (_isIdentStart(c)) {
      var j = i + 1;
      while (j < n && _isIdentChar(src.codeUnitAt(j))) {
        j++;
      }
      tokens.add(_Tok(_TokKind.ident, src.substring(start, j), start));
      i = j;
      continue;
    }
    throw DecodeException(
      'text format: unexpected character '
      '${String.fromCharCode(c)} at offset $start',
    );
  }
  tokens.add(_Tok(_TokKind.end, '', n));
  return tokens;
}

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
bool _isIdentChar(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);
bool _isNumberChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2e || // .
    c == 0x65 ||
    c == 0x45 || // e/E
    c == 0x2b ||
    c == 0x2d || // +/-
    c == 0x78 || // x (0x prefix)
    (c >= 0x41 && c <= 0x46) || // A-F (hex digits)
    (c >= 0x61 && c <= 0x66); // a-f (hex digits)

/// Scans a `"..."` string literal starting right after the opening quote,
/// producing raw bytes: escapes decode to a single byte each, and any other
/// (unescaped) character is UTF-8-re-encoded so multi-byte characters typed
/// directly in the source round-trip correctly. Reports the position right
/// after the closing quote via [setEnd].
List<int> _scanQuoted(String src, int start, void Function(int) setEnd) {
  final bytes = <int>[];
  var i = start;
  final n = src.length;
  while (true) {
    if (i >= n) {
      throw const DecodeException('text format: unterminated string literal');
    }
    final c = src.codeUnitAt(i);
    if (c == 0x22) {
      setEnd(i + 1);
      return bytes;
    }
    if (c == 0x5c) {
      i++;
      if (i >= n) {
        throw const DecodeException(
          'text format: unterminated escape sequence',
        );
      }
      final e = src.codeUnitAt(i);
      switch (e) {
        case 0x6e:
          bytes.add(0x0a);
          i++;
        case 0x72:
          bytes.add(0x0d);
          i++;
        case 0x74:
          bytes.add(0x09);
          i++;
        case 0x22:
          bytes.add(0x22);
          i++;
        case 0x27:
          bytes.add(0x27);
          i++;
        case 0x5c:
          bytes.add(0x5c);
          i++;
        case 0x61:
          bytes.add(0x07);
          i++;
        case 0x62:
          bytes.add(0x08);
          i++;
        case 0x66:
          bytes.add(0x0c);
          i++;
        case 0x76:
          bytes.add(0x0b);
          i++;
        case 0x78:
          if (i + 2 >= n) {
            throw const DecodeException('text format: incomplete \\x escape');
          }
          final hex = src.substring(i + 1, i + 3);
          final v = int.tryParse(hex, radix: 16);
          if (v == null) {
            throw DecodeException('text format: invalid \\x escape \\x$hex');
          }
          bytes.add(v);
          i += 3;
        case >= 0x30 && <= 0x37:
          // 1-3 octal digits.
          var j = i;
          var digits = 0;
          var value = 0;
          while (j < n &&
              digits < 3 &&
              src.codeUnitAt(j) >= 0x30 &&
              src.codeUnitAt(j) <= 0x37) {
            value = value * 8 + (src.codeUnitAt(j) - 0x30);
            j++;
            digits++;
          }
          bytes.add(value & 0xff);
          i = j;
        default:
          throw DecodeException(
            'text format: unsupported escape \\${String.fromCharCode(e)}',
          );
      }
      continue;
    }
    // Unescaped character: re-encode as UTF-8 in case it's multi-byte.
    final rune = src.runeAt(i);
    bytes.addAll(utf8.encode(String.fromCharCode(rune)));
    i += String.fromCharCode(rune).length;
  }
}

/// Scans a `0x"..."` hex-data literal starting right after the opening
/// quote. Whitespace between hex digit pairs is ignored (matches observed
/// `capnp encode` behavior, e.g. `0x"01 02 03"`).
List<int> _scanHexQuoted(String src, int start, void Function(int) setEnd) {
  final bytes = <int>[];
  var i = start;
  final n = src.length;
  final digits = StringBuffer();
  while (true) {
    if (i >= n) {
      throw const DecodeException('text format: unterminated hex data literal');
    }
    final c = src.codeUnitAt(i);
    if (c == 0x22) {
      if (digits.isNotEmpty) {
        throw const DecodeException(
          'text format: hex data literal has an odd number of digits',
        );
      }
      setEnd(i + 1);
      return bytes;
    }
    if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) {
      i++;
      continue;
    }
    digits.write(String.fromCharCode(c));
    i++;
    if (digits.length == 2) {
      final v = int.tryParse(digits.toString(), radix: 16);
      if (v == null) {
        throw DecodeException(
          'text format: invalid hex digits \'$digits\' in data literal',
        );
      }
      bytes.add(v);
      digits.clear();
    }
  }
}

extension on String {
  int runeAt(int index) => runes.elementAt(_runeIndexAt(index));
  int _runeIndexAt(int codeUnitIndex) {
    // Only ever called at the start of a rune (tokenizer/scanner never
    // splits a surrogate pair), so this is a plain code-unit-to-rune-index
    // walk, not a full rune decode.
    var count = 0;
    for (final _ in substring(0, codeUnitIndex).runes) {
      count++;
    }
    return count;
  }
}

// ---- Parser ----

// Keep hostile text input from exhausting the Dart stack before schema-aware
// materialization gets a chance to apply the normal message nesting limit.
const int _maxTextNestingDepth = 64;

class _TextParser {
  final List<_Tok> _tokens;
  final String _src;
  int _pos = 0;
  int _depth = 0;

  _TextParser(this._tokens, this._src);

  _Tok get _current => _tokens[_pos];

  DecodeException _error(String message) => DecodeException(
    'text format: $message near offset ${_current.pos} '
    '(${_context(_current.pos)})',
  );

  String _context(int pos) {
    final start = (pos - 10).clamp(0, _src.length);
    final end = (pos + 10).clamp(0, _src.length);
    return '...${_src.substring(start, end)}...';
  }

  _Tok _advance() {
    final t = _current;
    if (t.kind != _TokKind.end) _pos++;
    return t;
  }

  void _expect(_TokKind kind, String description) {
    if (_current.kind != kind) {
      throw _error('expected $description');
    }
    _advance();
  }

  void expectEnd() {
    if (_current.kind != _TokKind.end) {
      throw _error('unexpected trailing input');
    }
  }

  _TextValue parseValue() {
    final isContainer =
        _current.kind == _TokKind.lparen || _current.kind == _TokKind.lbracket;
    if (isContainer) {
      if (_depth >= _maxTextNestingDepth) {
        throw _error(
          'nesting depth exceeds the limit of $_maxTextNestingDepth',
        );
      }
      _depth++;
    }
    try {
      return _parseValueUnchecked();
    } finally {
      if (isContainer) _depth--;
    }
  }

  _TextValue _parseValueUnchecked() {
    switch (_current.kind) {
      case _TokKind.lparen:
        return _parseStruct();
      case _TokKind.lbracket:
        return _parseList();
      case _TokKind.string:
      case _TokKind.hexString:
        final t = _advance();
        return _TextBytes(t.bytes!);
      case _TokKind.number:
        return _TextNumber(_advance().text);
      case _TokKind.ident:
        return _TextIdent(_advance().text);
      case _TokKind.rparen:
      case _TokKind.rbracket:
      case _TokKind.equals:
      case _TokKind.comma:
      case _TokKind.end:
        throw _error('expected a value');
    }
  }

  _TextStruct _parseStruct() {
    _expect(_TokKind.lparen, '\'(\'');
    final fields = <String, _TextValue>{};
    // A trailing comma before the closing paren is allowed (idiomatic when
    // each field is on its own line, e.g. `(\n  a = 1,\n)`), so after each
    // comma re-check for the closing delimiter before demanding another
    // field.
    while (_current.kind != _TokKind.rparen) {
      if (_current.kind != _TokKind.ident) {
        throw _error('expected a field name');
      }
      final name = _advance().text;
      _expect(_TokKind.equals, '\'=\'');
      final value = parseValue();
      fields[name] = value;
      if (_current.kind == _TokKind.comma) {
        _advance();
        continue;
      }
      break;
    }
    _expect(_TokKind.rparen, '\')\'');
    return _TextStruct(fields);
  }

  _TextList _parseList() {
    _expect(_TokKind.lbracket, '\'[\'');
    final items = <_TextValue>[];
    // Same trailing-comma allowance as _parseStruct.
    while (_current.kind != _TokKind.rbracket) {
      items.add(parseValue());
      if (_current.kind == _TokKind.comma) {
        _advance();
        continue;
      }
      break;
    }
    _expect(_TokKind.rbracket, '\']\'');
    return _TextList(items);
  }
}

// ---- Materializer ----

void _materializeStruct(
  _TextStruct value,
  DynamicStructBuilder builder,
  StructSchemaInfo schema,
  SchemaRegistry registry,
) {
  final byName = {for (final f in schema.fields) f.name: f};
  for (final entry in value.fields.entries) {
    final field = byName[entry.key];
    if (field == null) {
      throw DecodeException(
        'text format: unknown field \'${entry.key}\' for struct '
        '${schema.displayName}',
      );
    }
    if (field.isUnionField) {
      builder.setUint16Field(
        schema.discriminantOffset * 2,
        field.discriminantValue,
      );
    }
    _materializeField(entry.value, builder, field, registry);
  }
}

void _materializeField(
  _TextValue value,
  DynamicStructBuilder builder,
  FieldSchemaInfo field,
  SchemaRegistry registry,
) {
  final body = field.body;
  if (body is GroupFieldSchemaInfo) {
    if (value is! _TextStruct) {
      throw DecodeException(
        'text format: expected a struct literal `(...)` for group field '
        '\'${field.name}\'',
      );
    }
    final groupSchema = _requireStructSchema(registry, body.typeId);
    // Groups share the parent's data/pointer sections — reuse this same
    // builder, not a nested allocation.
    _materializeStruct(value, builder, groupSchema, registry);
    return;
  }
  final slot = body as SlotFieldSchemaInfo;
  _materializeSlotValue(
    value,
    builder,
    slot.type,
    slot.offset,
    field.name,
    registry,
  );
}

void _materializeSlotValue(
  _TextValue value,
  DynamicStructBuilder builder,
  TypeSchemaInfo type,
  int offset,
  String fieldName,
  SchemaRegistry registry,
) {
  if (type is PrimitiveTypeSchemaInfo) {
    switch (type.name) {
      case 'Void':
        return; // nothing to write
      case 'Bool':
        builder.setBoolField(offset, _expectBool(value, fieldName));
        return;
      case 'Int8':
        builder.setInt8Field(offset, _expectInt(value, fieldName));
        return;
      case 'Int16':
        builder.setInt16Field(offset * 2, _expectInt(value, fieldName));
        return;
      case 'Int32':
        builder.setInt32Field(offset * 4, _expectInt(value, fieldName));
        return;
      case 'Int64':
        builder.setInt64Field(offset * 8, _expectInt(value, fieldName));
        return;
      case 'UInt8':
        builder.setUint8Field(offset, _expectInt(value, fieldName));
        return;
      case 'UInt16':
        builder.setUint16Field(offset * 2, _expectInt(value, fieldName));
        return;
      case 'UInt32':
        builder.setUint32Field(offset * 4, _expectInt(value, fieldName));
        return;
      case 'UInt64':
        builder.setUint64Field(offset * 8, _expectInt(value, fieldName));
        return;
      case 'Float32':
        builder.setFloat32Field(offset * 4, _expectDouble(value, fieldName));
        return;
      case 'Float64':
        builder.setFloat64Field(offset * 8, _expectDouble(value, fieldName));
        return;
      case 'Text':
        builder.setTextField(offset, _expectUtf8(value, fieldName));
        return;
      case 'Data':
        builder.setDataField(offset, _expectBytes(value, fieldName));
        return;
    }
    throw DecodeException(
      'text format: unsupported primitive type for field \'$fieldName\': '
      '${type.name}',
    );
  }
  if (type is EnumRefTypeSchemaInfo) {
    if (value is! _TextIdent) {
      throw DecodeException(
        'text format: expected an enumerant name for field \'$fieldName\'',
      );
    }
    builder.setUint16Field(
      offset * 2,
      _enumValue(type.typeId, value.name, registry, fieldName),
    );
    return;
  }
  if (type is StructRefTypeSchemaInfo) {
    if (value is! _TextStruct) {
      throw DecodeException(
        'text format: expected a struct literal `(...)` for field '
        '\'$fieldName\'',
      );
    }
    final structSchema = _requireStructSchema(registry, type.typeId);
    final nested = builder
        .initPointerField(offset)
        .initDynamicStruct(
          dataWords: structSchema.dataWords,
          pointerWords: structSchema.pointerWords,
        );
    _materializeStruct(value, nested, structSchema, registry);
    return;
  }
  if (type is ListTypeSchemaInfo) {
    if (value is! _TextList) {
      throw DecodeException(
        'text format: expected a list literal `[...]` for field '
        '\'$fieldName\'',
      );
    }
    _materializeList(
      value,
      builder.initPointerField(offset),
      type.elementType,
      registry,
      fieldName,
    );
    return;
  }
  if (type is InterfaceRefTypeSchemaInfo) {
    throw DecodeException(
      'text format: capabilities are not representable in text format '
      '(field \'$fieldName\')',
    );
  }
  throw DecodeException(
    'text format: AnyPointer/generic-typed fields are not representable in '
    'text format (field \'$fieldName\')',
  );
}

void _materializeList(
  _TextList value,
  AnyPointerBuilder ptr,
  TypeSchemaInfo elementType,
  SchemaRegistry registry,
  String fieldName,
) {
  final count = value.items.length;
  final elementSize = _elementSizeFor(elementType, registry, fieldName);
  var structDataWords = 0;
  var structPointerWords = 0;
  if (elementType is StructRefTypeSchemaInfo) {
    final structSchema = _requireStructSchema(registry, elementType.typeId);
    structDataWords = structSchema.dataWords;
    structPointerWords = structSchema.pointerWords;
  }
  final list = ptr.initDynamicList(
    elementSize: elementSize,
    count: count,
    structDataWords: structDataWords,
    structPointerWords: structPointerWords,
  );
  for (var i = 0; i < count; i++) {
    _materializeListElement(
      value.items[i],
      list,
      i,
      elementType,
      registry,
      fieldName,
    );
  }
}

ListElementSize _elementSizeFor(
  TypeSchemaInfo type,
  SchemaRegistry registry,
  String fieldName,
) {
  if (type is PrimitiveTypeSchemaInfo) {
    switch (type.name) {
      case 'Void':
        return ListElementSize.void_;
      case 'Bool':
        return ListElementSize.bit;
      case 'Int8':
      case 'UInt8':
        return ListElementSize.byte;
      case 'Int16':
      case 'UInt16':
        return ListElementSize.twoBytes;
      case 'Int32':
      case 'UInt32':
      case 'Float32':
        return ListElementSize.fourBytes;
      case 'Int64':
      case 'UInt64':
      case 'Float64':
        return ListElementSize.eightBytes;
      case 'Text':
      case 'Data':
        return ListElementSize.pointer;
    }
  }
  if (type is EnumRefTypeSchemaInfo) return ListElementSize.twoBytes;
  if (type is StructRefTypeSchemaInfo) return ListElementSize.composite;
  if (type is ListTypeSchemaInfo) return ListElementSize.pointer;
  throw DecodeException(
    'text format: unsupported list element type for field \'$fieldName\': '
    '$type',
  );
}

void _materializeListElement(
  _TextValue value,
  DynamicListBuilder list,
  int i,
  TypeSchemaInfo elementType,
  SchemaRegistry registry,
  String fieldName,
) {
  if (elementType is PrimitiveTypeSchemaInfo) {
    switch (elementType.name) {
      case 'Void':
        return;
      case 'Bool':
        list.setBool(i, _expectBool(value, fieldName));
        return;
      case 'Int8':
        list.setInt8(i, _expectInt(value, fieldName));
        return;
      case 'Int16':
        list.setInt16(i, _expectInt(value, fieldName));
        return;
      case 'Int32':
        list.setInt32(i, _expectInt(value, fieldName));
        return;
      case 'Int64':
        list.setInt64(i, _expectInt(value, fieldName));
        return;
      case 'UInt8':
        list.setUint8(i, _expectInt(value, fieldName));
        return;
      case 'UInt16':
        list.setUint16(i, _expectInt(value, fieldName));
        return;
      case 'UInt32':
        list.setUint32(i, _expectInt(value, fieldName));
        return;
      case 'UInt64':
        list.setUint64(i, _expectInt(value, fieldName));
        return;
      case 'Float32':
        list.setFloat32(i, _expectDouble(value, fieldName));
        return;
      case 'Float64':
        list.setFloat64(i, _expectDouble(value, fieldName));
        return;
      case 'Text':
        list.setText(i, _expectUtf8(value, fieldName));
        return;
      case 'Data':
        list.setData(i, _expectBytes(value, fieldName));
        return;
    }
  }
  if (elementType is EnumRefTypeSchemaInfo) {
    if (value is! _TextIdent) {
      throw DecodeException(
        'text format: expected an enumerant name in list \'$fieldName\'',
      );
    }
    list.setUint16(
      i,
      _enumValue(elementType.typeId, value.name, registry, fieldName),
    );
    return;
  }
  if (elementType is StructRefTypeSchemaInfo) {
    if (value is! _TextStruct) {
      throw DecodeException(
        'text format: expected a struct literal `(...)` in list '
        '\'$fieldName\'',
      );
    }
    final structSchema = _requireStructSchema(registry, elementType.typeId);
    _materializeStruct(value, list.getStruct(i), structSchema, registry);
    return;
  }
  if (elementType is ListTypeSchemaInfo) {
    if (value is! _TextList) {
      throw DecodeException(
        'text format: expected a list literal `[...]` in list '
        '\'$fieldName\'',
      );
    }
    final innerCount = value.items.length;
    final innerElementSize = _elementSizeFor(
      elementType.elementType,
      registry,
      fieldName,
    );
    var innerDataWords = 0;
    var innerPtrWords = 0;
    if (elementType.elementType is StructRefTypeSchemaInfo) {
      final s = _requireStructSchema(
        registry,
        (elementType.elementType as StructRefTypeSchemaInfo).typeId,
      );
      innerDataWords = s.dataWords;
      innerPtrWords = s.pointerWords;
    }
    final inner = list.initList(
      i,
      elementSize: innerElementSize,
      count: innerCount,
      structDataWords: innerDataWords,
      structPointerWords: innerPtrWords,
    );
    for (var j = 0; j < innerCount; j++) {
      _materializeListElement(
        value.items[j],
        inner,
        j,
        elementType.elementType,
        registry,
        fieldName,
      );
    }
    return;
  }
  throw DecodeException(
    'text format: unsupported list element type in \'$fieldName\': '
    '$elementType',
  );
}

int _enumValue(
  int typeId,
  String name,
  SchemaRegistry registry,
  String fieldName,
) {
  final sorted = _sortedEnumerants(_requireEnumSchema(registry, typeId));
  for (var i = 0; i < sorted.length; i++) {
    if (sorted[i].name == name) return i;
  }
  throw DecodeException(
    'text format: unknown enumerant \'$name\' for field \'$fieldName\'',
  );
}

bool _expectBool(_TextValue value, String fieldName) {
  if (value is _TextIdent && (value.name == 'true' || value.name == 'false')) {
    return value.name == 'true';
  }
  throw DecodeException(
    'text format: expected true/false for field \'$fieldName\'',
  );
}

int _expectInt(_TextValue value, String fieldName) {
  if (value is! _TextNumber) {
    throw DecodeException(
      'text format: expected a number for field \'$fieldName\'',
    );
  }
  final raw = value.raw;
  final v =
      raw.startsWith('0x') || raw.startsWith('-0x')
          ? _parseHexInt(raw)
          : int.tryParse(raw);
  if (v == null) {
    throw DecodeException(
      'text format: invalid integer \'$raw\' for field \'$fieldName\'',
    );
  }
  return v;
}

int _parseHexInt(String raw) {
  final negative = raw.startsWith('-');
  final unsigned = negative ? raw.substring(3) : raw.substring(2);
  final v = int.parse(unsigned, radix: 16);
  return negative ? -v : v;
}

double _expectDouble(_TextValue value, String fieldName) {
  if (value is _TextIdent) {
    switch (value.name) {
      case 'nan':
        return double.nan;
      case 'inf':
        return double.infinity;
      case '-inf':
        return double.negativeInfinity;
    }
  }
  if (value is _TextNumber) {
    final v = double.tryParse(value.raw);
    if (v != null) return v;
  }
  throw DecodeException(
    'text format: expected a floating-point number for field \'$fieldName\'',
  );
}

String _expectUtf8(_TextValue value, String fieldName) {
  if (value is! _TextBytes) {
    throw DecodeException(
      'text format: expected a string literal for field \'$fieldName\'',
    );
  }
  return utf8.decode(value.bytes);
}

Uint8List _expectBytes(_TextValue value, String fieldName) {
  if (value is! _TextBytes) {
    throw DecodeException(
      'text format: expected a string literal for field \'$fieldName\'',
    );
  }
  return Uint8List.fromList(value.bytes);
}
