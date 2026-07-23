## Unreleased

- Lowered `MessageBuilder`'s default first-segment allocation from 8 KiB to 2 KiB. CPU profiling showed the old default spent a disproportionate share of a typical small message's build time zeroing bytes it never used; 2 KiB keeps most of that win (~1.5-1.6x faster `encode (build + serialize)` in this package's benchmark) while measuring within noise of the old default on large, multi-segment messages. See `performance.md`.

## 0.1.0

- Initial version.
