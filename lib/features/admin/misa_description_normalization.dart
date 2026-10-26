import 'package:characters/characters.dart';
import 'misa_emoji_data.dart';

const misaDescriptionPolicy = 'misa-description-emoji-v1-unicode18';

class MisaDescriptionNormalization {
  const MisaDescriptionNormalization(this.original, this.text, this.removals);
  final String original, text;
  final List<Map<String, Object>> removals;
  bool get changed => removals.isNotEmpty;
}

bool _has(int value, List<(int, int)> ranges) {
  var lo = 0, hi = ranges.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    final (start, end) = ranges[mid];
    if (value < start) {
      hi = mid - 1;
    } else if (value > end) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

String _hex(int value) =>
    'U+${value.toRadixString(16).toUpperCase().padLeft(4, '0')}';
Never _invalid(String reason, int value, int offset) => throw FormatException(
  'MISA_DESCRIPTION_${reason}_${_hex(value)}_AT_$offset',
);

/// Changes only the exported Description. No NFC/ASCII conversion or blanket
/// non-BMP deletion. Remove whole extended grapheme clusters, including attached
/// emoji selectors, modifiers, tags and ZWJ. Plain text symbols remain text.
MisaDescriptionNormalization normalizeMisaDescription(String original) {
  for (var i = 0; i < original.length; i++) {
    final unit = original.codeUnitAt(i);
    int value = unit;
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 == original.length ||
          original.codeUnitAt(i + 1) < 0xDC00 ||
          original.codeUnitAt(i + 1) > 0xDFFF) {
        _invalid('INVALID_UTF16', unit, i);
      }
      value =
          0x10000 + ((unit - 0xD800) << 10) + original.codeUnitAt(++i) - 0xDC00;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      _invalid('INVALID_UTF16', unit, i);
    }
    if (value < 0x20 && value != 9 && value != 10 && value != 13 ||
        value == 0xFFFE ||
        value == 0xFFFF) {
      _invalid('INVALID_XML', value, i);
    }
  }
  final output = StringBuffer();
  final removals = <Map<String, Object>>[];
  var offset = 0;
  for (final cluster in original.characters) {
    final scalars = cluster.runes.toList(growable: false);
    bool emoji(int v) => _has(v, misaEmojiRanges);
    bool component(int v) => _has(v, misaEmojiComponentRanges) || v == 0xFE0E;
    bool asciiBase(int v) => v == 0x23 || v == 0x2A || v >= 0x30 && v <= 0x39;
    bool regional(int v) => v >= 0x1F1E6 && v <= 0x1F1FF;
    final keycap = scalars.contains(0x20E3) && asciiBase(scalars.first);
    final flag = scalars.length == 2 && scalars.every(regional);
    final componentOnly =
        scalars.every(component) &&
        !keycap &&
        !flag &&
        !(scalars.length == 1 && asciiBase(scalars.first));
    if (componentOnly) {
      _invalid('ORPHAN_EMOJI_COMPONENT', scalars.first, offset);
    }
    final decorative =
        flag ||
        keycap ||
        scalars.any(
          (v) =>
              !asciiBase(v) &&
              emoji(v) &&
              (_has(v, misaEmojiPresentationRanges) ||
                  v >= 0x1F000 && _has(v, misaExtendedPictographicRanges) ||
                  scalars.contains(0xFE0F) ||
                  scalars.contains(0x200D)),
        );
    if (decorative) {
      for (final scalar in scalars) {
        if (!emoji(scalar) && !component(scalar)) {
          _invalid('UNSUPPORTED_EMOJI_CLUSTER', scalar, offset);
        }
      }
      removals.add({
        'utf16_start': offset,
        'utf16_end': offset + cluster.length,
        'text': cluster,
        'code_points': scalars.map(_hex).toList(growable: false),
      });
    } else {
      if (scalars.contains(0xFE0F)) {
        _invalid('ORPHAN_EMOJI_SELECTOR', 0xFE0F, offset);
      }
      if (scalars.contains(0x200D)) {
        _invalid('NON_EMOJI_JOINER', 0x200D, offset);
      }
      output.write(cluster);
    }
    offset += cluster.length;
  }
  final text = output.toString();
  if (text.trim().isEmpty) {
    throw const FormatException('MISA_DESCRIPTION_EMPTY_AFTER_EMOJI_REMOVAL');
  }
  return MisaDescriptionNormalization(
    original,
    text,
    List.unmodifiable(removals),
  );
}
