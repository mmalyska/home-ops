#!/usr/bin/env bash
# mask.sh: stdin to stdout, hides the values of secret-looking keys and the nut MONITOR line.
# Works on unified-diff text (one prefix character per line: space, + or -) and on plain YAML.
# Block scalars are handled: under a secret-looking key the whole block is dropped, and any block
# scalar whose first content line is a PEM header ("-----BEGIN") is masked whatever its key
# (accepted CA list items). Other block scalars (TOML, kubelet settings) stay visible.
# Display filter only: it never changes what is compared, just what is shown.
awk '
function lead(s) { match(s, /^ */); return RLENGTH }
function sp(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
function mon(s) { sub(/MONITOR .*/, "MONITOR <masked>", s); return s }
BEGIN {
  secret = "^ *(- )?(crt|key|token|secret|secretboxEncryptionSecret|aescbcEncryptionSecret|password|id|bootstraptoken|clusterID|clusterSecret|cert|privateKey):"
  blockhdr = "^ *(- )?([^ :][^:]*:)? *[|>][-+0-9]*[ ]*$"
}
{
  line = $0
  if (line ~ /^@@/) { inblock = 0; pending = 0; print line; next }
  p = ""; b = line
  if (line ~ /^[ +-]/) { p = substr(line, 1, 1); b = substr(line, 2) }
  blank = (b ~ /^ *$/)

  if (inblock) {
    if (blank || lead(b) > blockindent) next
    inblock = 0
  }

  if (pending) {
    if (blank) { print line; next }
    if (lead(b) > pendindent) {
      t = b; sub(/^ */, "", t)
      if (t ~ /^-----BEGIN/) {
        print p sp(pendindent + 2) "<masked>"
        inblock = 1; blockindent = pendindent; pending = 0
        next
      }
    }
    pending = 0
  }

  if (b ~ secret) {
    colon = index(b, ":")
    rest = substr(b, colon + 1); sub(/^ */, "", rest)
    if (rest ~ /^[|>][-+0-9]*[ ]*$/) { inblock = 1; blockindent = lead(b) }
    print mon(p substr(b, 1, colon - 1) ": <masked>")
    next
  }

  if (b ~ blockhdr) { pending = 1; pendindent = lead(b) }
  print mon(line)
}'
