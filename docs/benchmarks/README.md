# Performance experiments

The current implementation uses Ruby only.
The [final Ruby storage study](final-ruby-storage/README.md) selects the `rb04` format across application, nested, numeric, and continuity datasets.
It covers 58, 1,000, and 10,000 rows on file and memory stores, with unchanged acceptance limits and an explicit balanced confirmation.
The recorded statistics, correctness evidence, and source hashes can be reproduced from its archives.
The original all-case Core JSON parity target remains unmet.

Earlier studies under `native-batch`, `native-pages`, `native-decode`, `native-encode`, `native-adapters`, `native-production`, `native-input-guard`, `native-row-edits`, and `native-root-cursors` include a C extension.

Those archives document historical experiments. Their measurements do not establish the performance of the Ruby-only implementation.

The C implementation and its build steps have been removed from the library. Replay scripts for historical studies are outside the current build and test workflow.

Ruby-only measurements must identify their production sources, datasets, and comparison controls.
Historical studies do not establish performance for a later implementation.

The [Ruby-only page baseline](ruby-only-pages/README.md) measures commit `3085ce4` across all six groups. Correctness checks pass; the performance target remains unmet.
