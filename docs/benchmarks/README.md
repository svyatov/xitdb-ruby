# Performance experiments

The current implementation must use Ruby only. The performance target covers all six measured groups: 58, 1,000, and 10,000 rows with file and memory stores.

Earlier studies under `native-batch`, `native-pages`, `native-decode`, `native-encode`, `native-adapters`, `native-production`, `native-input-guard`, `native-row-edits`, and `native-root-cursors` include a C extension.

Those archives document historical experiments. Their measurements do not establish the performance of the Ruby-only implementation.

The C implementation and its build steps have been removed from the library. Replay scripts for historical studies are outside the current build and test workflow.

Ruby-only measurements must use the current production code and repeat the six groups before the performance goal can be declared complete.

The [Ruby-only page baseline](ruby-only-pages/README.md) measures commit `3085ce4` across all six groups. Correctness checks pass; the performance target remains unmet.
