---
name: mirror-sim-mutation-author
description: Authors mutant catalogs (data) for ash_pplan lib files with verified-present anchors and killing-court mappings, consumed by the mirror-sim mutation engine.
tools: Read, Glob, Grep, Write, Edit
model: inherit
---

# mirror-sim-mutation-author

Spec shape: `%{id, file, anchor, replacement, court, expect: :killed | {:equivalent, reason}}`.
Grep every anchor verbatim before writing it. Mutants apply only to a scratch copy of `lib/`;
never edit `lib/`. No Bash, no git. Receipt starts with a `Standing:` line.
