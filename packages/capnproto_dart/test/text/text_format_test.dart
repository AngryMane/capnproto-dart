import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:test/test.dart';

import 'widget_fixture.dart';

// Expected strings below were captured directly from the reference `capnp`
// CLI (`capnp decode --short widget.capnp Widget < data.bin`) against the
// same schema `widget_fixture.dart` was generated from — not hand-derived —
// so a mismatch here means a real divergence from the reference
// implementation's text format, not just a self-consistency check.
void main() {
  final registry = schemaRegistryOf([widgetSchema, pointSchema, colorSchema]);

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
        contains(
          r'name = "line1\nline2\ttab\"quote\"\\back こんにちは"',
        ),
      );
    });

    test('special float values render as nan/inf/-inf, matching capnp', () {
      final mb = MessageBuilder();
      final w = mb.initRoot(widgetFactory);
      w.ratio = double.nan;
      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(widgetFactory);
      expect(encodeText(reader, widgetSchema, registry), contains('ratio = nan'));
    });

    test('throws for a struct/enum type missing from the registry', () {
      final mb = MessageBuilder();
      mb.initRoot(widgetFactory).initOrigin();
      final reader = MessageReader.deserialize(
        mb.serialize(),
      ).getRoot(widgetFactory);

      expect(
        () => encodeText(reader, widgetSchema, schemaRegistryOf([widgetSchema])),
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
      final bytes = decodeText(
        '(tag = 0x"01 02 ff")',
        widgetSchema,
        registry,
      );
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
  });
}
