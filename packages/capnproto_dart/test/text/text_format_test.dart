import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:test/test.dart';

import 'extras_fixture.dart';
import 'signal_fixture.dart';
import 'widget_fixture.dart';

// Expected strings below were captured directly from the reference `capnp`
// CLI (`capnp decode --short widget.capnp Widget < data.bin`) against the
// same schema `widget_fixture.dart` was generated from — not hand-derived —
// so a mismatch here means a real divergence from the reference
// implementation's text format, not just a self-consistency check.
void main() {
  final registry = schemaRegistryOf([widgetSchema, pointSchema, colorSchema]);
  final extrasRegistry = schemaRegistryOf([
    extrasSchema,
    posSchema,
    smallEnumSchema,
  ]);

  String encodeExtras(void Function(ExtrasBuilder) build) {
    final mb = MessageBuilder();
    build(mb.initRoot(extrasFactory));
    final reader = MessageReader.deserialize(
      mb.serialize(),
    ).getRoot(extrasFactory);
    return encodeText(reader, extrasSchema, extrasRegistry);
  }

  group('encodeText', () {
    test('matches capnp decode --short for a fully-populated struct', () {
      final mb = MessageBuilder();
      final w = mb.initRoot(widgetFactory);
      w.name = 'hello';
      w.tag = Uint8List.fromList([1, 2, 3]);
      w.size = 42;
      w.ratio = 3.14;
      w.active = true;
      w.color = Color.green;
      w.initOrigin()
        ..x = 1
        ..y = 2;
      final tags = w.initTags(3);
      tags[0] = 'a';
      tags[1] = 'b';
      tags[2] = 'c';
      final points = w.initPoints(2);
      points[0].x = 1;
      points[0].y = 2;
      points[1].x = 3;
      points[1].y = 4;
      final nums = w.initNums(3);
      nums[0] = 1;
      nums[1] = 2;
      nums[2] = 3;
      w.b = 'hi';

      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(widgetFactory);

      expect(
        encodeText(reader, widgetSchema, registry),
        '(name = "hello", tag = "\\001\\002\\003", size = 42, ratio = 3.14, '
        'active = true, color = green, origin = (x = 1, y = 2), '
        'tags = ["a", "b", "c"], points = [(x = 1, y = 2), (x = 3, y = 4)], '
        'nums = [1, 2, 3], b = "hi")',
      );
    });

    test('an all-defaults struct shows scalar fields but omits unset '
        'pointer fields (matches capnp: `(size = 0, ratio = 0, active = '
        'false, color = red, a = 0)`)', () {
      final mb = MessageBuilder();
      mb.initRoot(widgetFactory); // everything left at its default
      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(widgetFactory);

      expect(
        encodeText(reader, widgetSchema, registry),
        '(size = 0, ratio = 0, active = false, color = red, a = 0)',
      );
    });

    test('text escaping matches capnp for control chars, quotes, and '
        'non-ASCII Unicode', () {
      final mb = MessageBuilder();
      final w = mb.initRoot(widgetFactory);
      w.name = 'line1\nline2\ttab"quote"\\back こんにちは';
      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(widgetFactory);

      expect(
        encodeText(reader, widgetSchema, registry),
        contains(r'name = "line1\nline2\ttab\"quote\"\\back こんにちは"'),
      );
    });

    test('special float values render as nan/inf/-inf, matching capnp', () {
      final mb = MessageBuilder();
      final w = mb.initRoot(widgetFactory);
      w.ratio = double.nan;
      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(widgetFactory);
      expect(
        encodeText(reader, widgetSchema, registry),
        contains('ratio = nan'),
      );
    });

    test('special floats and negative zero match capnp spelling', () {
      for (final (value, spelling) in [
        (double.nan, 'nan'),
        (double.infinity, 'inf'),
        (double.negativeInfinity, '-inf'),
        (-0.0, '-0'),
      ]) {
        final mb = MessageBuilder();
        mb.initRoot(widgetFactory).ratio = value;
        final reader = MessageReader.deserialize(
          mb.serialize(),
        ).getRoot(widgetFactory);
        expect(
          encodeText(reader, widgetSchema, registry),
          contains('ratio = $spelling'),
        );
      }
    });

    test('distinguishes an unset list pointer from an explicit empty list', () {
      final unset = MessageBuilder()..initRoot(widgetFactory);
      expect(
        encodeText(
          MessageReader.deserialize(unset.serialize()).getRoot(widgetFactory),
          widgetSchema,
          registry,
        ),
        isNot(contains('tags =')),
      );

      final empty = MessageBuilder()..initRoot(widgetFactory).initTags(0);
      expect(
        encodeText(
          MessageReader.deserialize(empty.serialize()).getRoot(widgetFactory),
          widgetSchema,
          registry,
        ),
        contains('tags = []'),
      );
    });
    test('throws for a struct/enum type missing from the registry', () {
      final mb = MessageBuilder();
      mb.initRoot(widgetFactory).initOrigin();
      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(widgetFactory);

      expect(
        () =>
            encodeText(reader, widgetSchema, schemaRegistryOf([widgetSchema])),
        throwsA(isA<DecodeException>()),
      );
    });
  });

  group('decodeText', () {
    test('round-trips the same text capnp encode/decode would produce', () {
      const text =
          '(name = "hello", tag = "\\001\\002\\003", size = 42, '
          'ratio = 3.14, active = true, color = green, '
          'origin = (x = 1, y = 2), tags = ["a", "b", "c"], '
          'points = [(x = 1, y = 2), (x = 3, y = 4)], nums = [1, 2, 3], '
          'b = "hi")';

      final bytes = decodeText(text, widgetSchema, registry);
      final w = MessageReader.deserialize(bytes).getRoot(widgetFactory);

      expect(w.name, 'hello');
      expect(w.tag, orderedEquals([1, 2, 3]));
      expect(w.size, 42);
      expect(w.ratio, 3.14);
      expect(w.active, isTrue);
      expect(w.color, Color.green);
      expect(w.origin?.x, 1);
      expect(w.origin?.y, 2);
      expect(w.tags?.toList(), ['a', 'b', 'c']);
      expect(w.points?.map((p) => (p.x, p.y)).toList(), [(1, 2), (3, 4)]);
      expect(w.nums?.toList(), [1, 2, 3]);
      expect(w.which, 1); // union member b active
      expect(w.b, 'hi');

      // And it round-trips back through encodeText identically.
      expect(
        encodeText(w, widgetSchema, registry),
        '(name = "hello", tag = "\\001\\002\\003", size = 42, ratio = 3.14, '
        'active = true, color = green, origin = (x = 1, y = 2), '
        'tags = ["a", "b", "c"], points = [(x = 1, y = 2), (x = 3, y = 4)], '
        'nums = [1, 2, 3], b = "hi")',
      );
    });

    test('parses hex data literals (0x"...")', () {
      final bytes = decodeText('(tag = 0x"01 02 ff")', widgetSchema, registry);
      final w = MessageReader.deserialize(bytes).getRoot(widgetFactory);
      expect(w.tag, orderedEquals([1, 2, 0xff]));
    });

    test('parses \\x hex escapes and negative/hex numbers', () {
      final bytes = decodeText(
        '(name = "a\\x01b", size = 4294967295)',
        widgetSchema,
        registry,
      );
      final w = MessageReader.deserialize(bytes).getRoot(widgetFactory);
      expect(w.name, 'ab');
      expect(w.size, 4294967295);
    });

    test('parses the union member \'a\' branch and clears \'b\'', () {
      final bytes = decodeText('(a = 7)', widgetSchema, registry);
      final w = MessageReader.deserialize(bytes).getRoot(widgetFactory);
      expect(w.which, 0);
      expect(w.a, 7);
    });

    test('parses comments and whitespace/newlines like a real .capnp text '
        'file', () {
      final bytes = decodeText(
        '(\n  # a comment\n  size = 5,\n)',
        widgetSchema,
        registry,
      );
      final w = MessageReader.deserialize(bytes).getRoot(widgetFactory);
      expect(w.size, 5);
    });

    test('parses nan, inf, -inf, and negative zero', () {
      for (final (literal, check) in [
        ('nan', (double value) => value.isNaN),
        ('inf', (double value) => value == double.infinity),
        ('-inf', (double value) => value == double.negativeInfinity),
        ('-0', (double value) => value == 0 && value.isNegative),
      ]) {
        final bytes = decodeText('(ratio = $literal)', widgetSchema, registry);
        final value =
            MessageReader.deserialize(bytes).getRoot(widgetFactory).ratio;
        expect(check(value), isTrue, reason: literal);
      }
    });

    test('matches capnp duplicate-field behavior: the last value wins', () {
      final bytes = decodeText('(size = 1, size = 2)', widgetSchema, registry);
      expect(MessageReader.deserialize(bytes).getRoot(widgetFactory).size, 2);
    });

    test('rejects malformed escapes, hex data, commas, and trailing input', () {
      for (final text in [
        r'(name = "\q")',
        r'(tag = 0x"0")',
        '(size = 1,,)',
        '(size = 1) trailing',
      ]) {
        expect(
          () => decodeText(text, widgetSchema, registry),
          throwsA(isA<DecodeException>()),
          reason: text,
        );
      }
    });

    test('rejects text nesting deeper than the parser limit', () {
      final deeplyNested = '(tags = ${'[' * 65}${']' * 65})';
      expect(
        () => decodeText(deeplyNested, widgetSchema, registry),
        throwsA(
          isA<DecodeException>().having(
            (error) => error.message,
            'message',
            contains('nesting depth exceeds the limit of 64'),
          ),
        ),
      );
    });
    test('throws DecodeException for an unknown field name', () {
      expect(
        () => decodeText('(bogus = 1)', widgetSchema, registry),
        throwsA(isA<DecodeException>()),
      );
    });

    test('throws DecodeException for a syntax error', () {
      expect(
        () => decodeText('(size = )', widgetSchema, registry),
        throwsA(isA<DecodeException>()),
      );
    });

    test('throws DecodeException for an unknown enumerant name', () {
      expect(
        () => decodeText('(color = purple)', widgetSchema, registry),
        throwsA(isA<DecodeException>()),
      );
    });

    test('accepts a trailing comma inside a list literal, like the real '
        'capnp CLI does', () {
      final bytes = decodeText(
        '(nums = [1, 2, 3,])',
        widgetSchema,
        registry,
      );
      final w = MessageReader.deserialize(bytes).getRoot(widgetFactory);
      expect(w.nums?.toList(), [1, 2, 3]);
    });
  });

  // Extras/SmallEnum-based tests below cover cases `widget_fixture.dart`
  // doesn't: a group field, an out-of-range enumerant, Int64/UInt64
  // boundary values, Float32 rounding, and a field with a non-zero explicit
  // default. Expected strings were captured the same way as above: directly
  // from the reference `capnp` CLI (`capnp decode --short extras.capnp
  // Extras < data.bin`) against the schema `extras_fixture.dart` was
  // generated from.
  group('encodeText — group fields, wide integers, Float32, and enums '
      '(extras_fixture)', () {
    test('an all-defaults struct always shows scalar/group fields '
        '(matches capnp: scalar and group fields have no absence bit, '
        'unlike pointer fields)', () {
      expect(
        encodeExtras((e) {}),
        '(i8 = 0, i64 = 0, u64 = 0, f32 = 0, count = 5, '
        'pos = (gx = 0, gy = 0), small = only, ua = 0)',
      );
    });

    test('a field with a non-zero explicit default is shown even when '
        'equal to its default — indistinguishable from being left unset, '
        'matching capnp (both scalar presence and value come from the '
        'same XORed-with-default wire representation)', () {
      expect(
        encodeExtras((e) => e.count = 5),
        encodeExtras((e) {}),
      );
    });

    test('a scalar field set to a non-default value is shown with that '
        'value', () {
      expect(encodeExtras((e) => e.count = 7), contains('count = 7'));
    });

    test('a group field is always rendered as a nested struct literal, '
        'using the parent\'s own storage (no pointer indirection)', () {
      expect(
        encodeExtras((e) => e.pos
          ..gx = 1
          ..gy = 2),
        contains('pos = (gx = 1, gy = 2)'),
      );
    });

    test('Int8/Int64/UInt64 boundary values match capnp exactly', () {
      expect(
        encodeExtras((e) {
          e.i8 = -128;
          e.i64 = -9223372036854775808;
          e.u64 = -1; // wire bit pattern for 0xFFFFFFFFFFFFFFFF
        }),
        contains(
          'i8 = -128, i64 = -9223372036854775808, '
          'u64 = 18446744073709551615',
        ),
      );
      expect(encodeExtras((e) => e.i8 = 127), contains('i8 = 127'));
    });

    test('Float32 fields use Float32-precision shortest round-trip '
        'formatting, not Float64\'s (matches capnp; a naive float64 '
        'toString on the widened value would show extra garbage digits '
        'like 3.140000104904175)', () {
      expect(encodeExtras((e) => e.f32 = 3.14), contains('f32 = 3.14'));
      expect(encodeExtras((e) => e.f32 = 1.1), contains('f32 = 1.1'));
    });

    test('each union discriminant is rendered under its own field name', () {
      expect(encodeExtras((e) => e.ua = 5), contains('ua = 5'));
      expect(encodeExtras((e) => e.ub = true), contains('ub = true'));
      expect(encodeExtras((e) => e.uc = 'hi'), contains('uc = "hi"'));
    });

    test('an out-of-range/unknown enumerant renders as a parenthesized raw '
        'ordinal, matching capnp\'s own rendering for a message produced '
        'under a newer schema with more enumerants (verified by encoding '
        'under a real capnp schema with 6 enumerants and decoding under one '
        'with only 1)', () {
      expect(encodeExtras((e) => e.smallRaw = 5), contains('small = (5)'));
    });
  });

  group('decodeText — group fields, wide integers, Float32, and enums '
      '(extras_fixture)', () {
    Object decodeExtras(String text) {
      final bytes = decodeText(text, extrasSchema, extrasRegistry);
      return MessageReader.deserialize(bytes).getRoot(extrasFactory);
    }

    test('parses a group field literal into the parent\'s own storage', () {
      final w =
          decodeExtras('(pos = (gx = 1, gy = 2))') as ExtrasReader;
      expect(w.pos.gx, 1);
      expect(w.pos.gy, 2);
    });

    test('parses Int64/UInt64 boundary literals that don\'t fit a signed '
        '64-bit int when read as plain decimal (UInt64 max in particular '
        'needs BigInt parsing, not int.tryParse, since it overflows a '
        "Dart int)", () {
      final w =
          decodeExtras(
                '(i64 = -9223372036854775808, u64 = 18446744073709551615)',
              )
              as ExtrasReader;
      expect(w.i64, -9223372036854775808);
      expect(w.u64, -1); // wire bit pattern for 0xFFFFFFFFFFFFFFFF
    });

    test('parses a Float32 literal', () {
      final w = decodeExtras('(f32 = 3.14)') as ExtrasReader;
      expect(w.f32, closeTo(3.14, 1e-6));
    });

    test('parses each union discriminant', () {
      expect((decodeExtras('(ua = 5)') as ExtrasReader).which, 0);
      expect((decodeExtras('(ub = true)') as ExtrasReader).which, 1);
      expect((decodeExtras('(uc = "hi")') as ExtrasReader).which, 2);
    });

    test('rejects an out-of-range integer literal instead of silently '
        'wrapping it, matching capnp\'s own "Integer value out of range" '
        'rejection (verified directly against the real capnp CLI for each '
        'of these)', () {
      for (final text in [
        '(i8 = 300)', // Int8 max is 127
        '(i8 = -200)', // Int8 min is -128
        '(u64 = -1)', // capnp rejects a negative literal for an unsigned field
        '(u64 = 18446744073709551616)', // one past UInt64 max (2^64)
        '(i64 = 9223372036854775808)', // one past Int64 max
        '(i64 = -9223372036854775809)', // one past Int64 min
      ]) {
        expect(
          () => decodeExtras(text),
          throwsA(isA<DecodeException>()),
          reason: text,
        );
      }
    });

    test('still accepts the exact boundary values (not off-by-one too '
        'strict)', () {
      expect((decodeExtras('(i8 = -128)') as ExtrasReader).i8, -128);
      expect((decodeExtras('(i8 = 127)') as ExtrasReader).i8, 127);
      expect(
        (decodeExtras('(u64 = 18446744073709551615)') as ExtrasReader).u64,
        -1, // wire bit pattern for 0xFFFFFFFFFFFFFFFF
      );
    });
  });

  group('encodeText/decodeText — enum @N declared out of declaration order '
      '(signal_fixture)', () {
    // Level's `@N`s are deliberately out of declaration order (low=0,
    // high=2, medium=1) — regression coverage for the codeOrder-vs-ordinal
    // bug: capnpc-dart used to sort/emit enumerants by codeOrder (textual
    // declaration order), so a schema like this one produced a Dart `enum`
    // whose `.index` didn't match the real wire value at all.
    final signalRegistry = schemaRegistryOf([signalSchema, levelSchema]);

    String encodeSignal(Level level) {
      final mb = MessageBuilder();
      mb.initRoot(signalFactory).level = level;
      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(signalFactory);
      return encodeText(reader, signalSchema, signalRegistry);
    }

    test('each enumerant encodes to its own name, not a swapped one, '
        'matching the real capnp CLI', () {
      expect(encodeSignal(Level.low), '(level = low)');
      expect(encodeSignal(Level.medium), '(level = medium)');
      expect(encodeSignal(Level.high), '(level = high)');
    });

    test('the Dart enum member order matches wire ordinal (`@N`), not '
        'declaration order — Level.high.index must be 2 (its `@N`), not 1 '
        '(its declaration position)', () {
      expect(Level.low.index, 0);
      expect(Level.medium.index, 1);
      expect(Level.high.index, 2);
    });

    test('decodeText parses each enumerant name to its correct wire value', () {
      for (final (text, level) in [
        ('(level = low)', Level.low),
        ('(level = medium)', Level.medium),
        ('(level = high)', Level.high),
      ]) {
        final bytes = decodeText(text, signalSchema, signalRegistry);
        final w = MessageReader.deserialize(bytes).getRoot(signalFactory);
        expect(w.level, level, reason: text);
      }
    });
  });
}
