---
name: nvidia-oot conftest system fails in Talos pkgs build — use static compat header
description: conftest.sh probes silently fail in Talos build env; use static NV_* header instead
type: feedback
---

`conftest.sh` probe programs start with `#include "conftest/headers.h"` but `build_cflags()` inside conftest.sh never adds `-I/conftest`, so all probes silently fail and every `NV_*` macro is left undefined.

`EXTRA_CFLAGS` passed to the conftest Makefile does NOT fix this — it only affects Makefile-level compilation, not the internal shell `$CC` invocations inside `conftest.sh`.

**Fix:** Skip conftest entirely — create `files/<module>_compat.h` that directly `#define`s the correct `NV_*` values for the target kernel, install it as `/conftest/nvidia/conftest.h`, add `KCPPFLAGS="-I/conftest"` so `#include <nvidia/conftest.h>` resolves to the static file.

**To port to another module:** `grep -r '#if defined(NV_' drivers/path/to/module/ | grep -oP 'NV_[A-Z_0-9]+' | sort -u` — for each macro read the version comment in the source and define it if version <= target kernel.

**NEVER** define `NV_MODULE_IMPORT_NS_CALLS_STRINGIFY` for kernel 6.18+ — it uses string-literal `MODULE_IMPORT_NS("NS")` not the STRINGIFY macro form.

Reference: `nvmap-driver/files/nvmap_compat.h` covers all 14 macros for Linux 6.18.

**How to apply:** When adding any new nvidia OOT module to the pkgs fork, use this static header approach from the start.
