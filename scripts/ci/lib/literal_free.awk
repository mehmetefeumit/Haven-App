# literal_free(t): the source line `t` with the contents of every string and
# char literal that opens and closes on it removed, and a trailing line
# comment cut — what a guard counts braces on, so that a `{` or `}` inside
# "...", r"...", r#"..."#, br#"..."# or '{' does not end (or never end) the block it is
# walking.
#
# Line by line, with no state: a literal left open at the end of the line —
# a string that spans lines, or one a comment-stripper already cut at a `//`
# inside it ("wss://") — is left as it is from its opening quote on, so its
# braces count as they always did; so do those of a line that starts inside
# one. A Dart string in single quotes longer than one character is left as it
# is too, `//` inside it included.
#
# Shared by every guard that walks braces; included by text, e.g.
#   awk "${LITERAL_FREE}"' { lfree = literal_free($0); ... }'
function literal_free(t,    out, i, n, c, j, hashes, closer, end) {
  out = ""
  n = length(t)
  for (i = 1; i <= n; i++) {
    c = substr(t, i, 1)
    if (c == "/" && substr(t, i + 1, 1) == "/") break
    # A raw string, its byte form (`br"…"`, `br#"…"#`) included.
    if (c == "r" && (i == 1 || substr(t, i - 1, 1) !~ /[A-Za-z0-9_]/ \
        || (substr(t, i - 1, 1) == "b" && (i == 2 || substr(t, i - 2, 1) !~ /[A-Za-z0-9_]/)))) {
      j = i + 1
      hashes = 0
      while (substr(t, j, 1) == "#") { hashes++; j++ }
      if (substr(t, j, 1) == "\"") {
        closer = "\"" substr("################", 1, hashes)
        end = index(substr(t, j + 1), closer)
        if (end == 0) return out substr(t, i)
        i = j + end + length(closer) - 1
        continue
      }
    }
    if (c == "\"") {
      for (j = i + 1; j <= n; j++) {
        if (substr(t, j, 1) == "\\") { j++; continue }
        if (substr(t, j, 1) == "\"") break
      }
      if (j > n) return out substr(t, i)
      i = j
      continue
    }
    # Outside a literal a backslash only appears on a line that starts inside
    # a multi-line string; the quote it escapes opens nothing.
    if (c == "\\") { i++; continue }
    # A char literal follows punctuation or a byte prefix, never a word or a
    # quote: `''` and `error'}'` are the ends of Dart strings, and taken as
    # chars they swallow the `}` closing an interpolation.
    if (c == "'" && (i == 1 || substr(t, i - 1, 1) !~ /[A-Za-z0-9_']/ \
        || (substr(t, i - 1, 1) == "b" && (i == 2 || substr(t, i - 2, 1) !~ /[A-Za-z0-9_]/)))) {
      if (substr(t, i + 1, 1) == "\\") {
        j = index(substr(t, i + 3), "'")
        if (j > 0 && j <= 8) { i += j + 2; continue }
      }
      if (substr(t, i + 2, 1) == "'" && substr(t, i + 1, 1) != "'") { i += 2; continue }
    }
    out = out c
  }
  return out
}
