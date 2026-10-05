#!/usr/bin/env bash
# mask.sh: stdin to stdout, hides the values of secret-looking keys and the nut MONITOR line.
# Display filter only: it never changes what is compared, just what is shown.
sed -E '
  s/^([ +-]*(- )?)(crt|key|token|secret|secretboxEncryptionSecret|aescbcEncryptionSecret|password|id|bootstraptoken):[ ]*.*/\1\3: <masked>/
  s/MONITOR .*/MONITOR <masked>/
'
