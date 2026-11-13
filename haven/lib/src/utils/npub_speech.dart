/// Speaking a displayed npub to a screen reader.
///
/// Shared by every row that carries the "Read public key aloud" custom
/// action — the picker's rows and the staged-member tile — for the same
/// reason: a resolved name keeps the raw key out of the main label, so this
/// action is the only way a screen-reader user can still hear it for
/// verification.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Speaks [shortNpub] aloud, chunked into pronounceable groups.
Future<void> speakNpub(BuildContext context, String shortNpub) {
  return SemanticsService.sendAnnouncement(
    View.of(context),
    chunkNpubForSpeech(shortNpub),
    TextDirection.ltr,
  );
}

/// The elision `NpubValidator.shortenForDisplay` puts between the retained
/// prefix and suffix. Bech32's data charset has no `.`, so this substring
/// can only ever be the elision itself, never a data character.
const _npubElision = '...';

/// Groups [shortNpub] into runs of four so a screen reader reads a key as
/// separable pieces instead of one unpronounceable word.
///
/// Purely a rendering of the SAME characters, in the same order: strip the
/// spaces and the original is back, which is what makes it usable for
/// checking a key against one read aloud elsewhere.
///
/// The retained prefix and suffix either side of the elision are chunked
/// INDEPENDENTLY, with the elision left as its own token, rather than
/// chunking the whole string end to end (plan F5): a flat every-four split
/// cuts across the elision boundary at Haven's 12/6 format, fusing the dots
/// to the first checksum character and leaving a one-character final
/// chunk — so depending on a TTS engine's punctuation verbosity the elision
/// is spoken, paused over, or dropped, and in the last case the two
/// retained runs are heard as one contiguous key, exactly what the
/// truncation exists to prevent. A string with no elision (an untruncated
/// npub) falls back to one flat run.
String chunkNpubForSpeech(String shortNpub) {
  final splitAt = shortNpub.indexOf(_npubElision);
  if (splitAt == -1) return _chunkRun(shortNpub).join(' ');
  final prefix = shortNpub.substring(0, splitAt);
  final suffix = shortNpub.substring(splitAt + _npubElision.length);
  return [..._chunkRun(prefix), _npubElision, ..._chunkRun(suffix)].join(' ');
}

/// Splits [run] into consecutive four-character groups, the last as short
/// as one character when [run]'s length is not a multiple of four.
List<String> _chunkRun(String run) {
  final chunks = <String>[];
  for (var i = 0; i < run.length; i += 4) {
    chunks.add(run.substring(i, (i + 4).clamp(0, run.length)));
  }
  return chunks;
}
