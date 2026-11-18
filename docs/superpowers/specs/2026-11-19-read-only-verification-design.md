# Read-only database verification

## Purpose

A restore process needs to decide whether a staged file contains a structurally readable latest snapshot. Opening that file and reading a few keys can miss a malformed cell in another row of a checksummed page. Verification follows the latest committed root to every reachable value and stops at the first defect. A successful result applies to that snapshot and the checks listed below. Earlier snapshots, unreachable bytes, application rules and payload authenticity are outside its scope.

## Approaches

We chose a dedicated verifier. It reads storage records directly and reuses the format readers where they enforce the required checks within the verifier's limits. It can identify the source offset while examining a record. A second traversal must stay in sync with new storage layouts.

We also considered extracting a traversal from compaction. That would share pointer handling, but would change the existing copy operation. The verifier still needs to inspect profile data that compaction can copy as bytes.

## Public contract

The proposed Ruby entry point is `XitDB.verify!(path)` after `require "xitdb"`. It opens one existing file read-only, selects the profile from its header and closes the descriptor on every exit. It accepts the portable builtin hash identifiers and widths recognized by the public reader, and Ruby `rb05` with width 32. Unknown identifiers, legacy Ruby profiles and unsupported Core versions produce an unsupported-format error. Verification requires no codec registry.

Success returns an immutable result with the profile (`:portable` or `:ruby`), hash identifier, hash width in bytes, exclusive committed byte boundary and distinct application codec IDs encountered. Bound the total storage for this inventory under the same resource-limit policy as traversal. A valid initialized file with no history succeeds as an empty snapshot. A missing file raises the ordinary filesystem error. A zero-byte file fails verification.

The first confirmed defect raises a verification error derived from `CorruptionError`. It carries a check identifier, a short message, the absolute byte offset when known and a bounded logical path when available. Use the start of the affected page for a checksum failure. Include a row or field only when the parser can identify it. Unsupported formats, operating-system failures and exhausted verification budgets have distinct errors. Only a successful return authorizes acceptance.

## Scan

Capture the committed size and checked root trailer together through Core's snapshot semantics. Keep that descriptor and boundary for the entire scan, including profile reads. Follow the history index just far enough to select the latest root. Later appends and unpublished tail bytes are outside the captured snapshot. In-place external modification of already committed bytes is outside the storage concurrency contract.

Validate the latest root's public map representation. Check the width and extent of each reachable record, valid slot tags for each position, child references, visible array ranges, counts, hash routing and stored key hashes, and tree ordering, separators and subtree sizes as applicable. Use the profile's stored key comparison and equality rules. Follow every visible child. Hidden positions in shared partial arrays may belong to another view. An active ancestor reference is a cycle. Reuse of a completed record is legal when it satisfies the referring position's layout and visibility requirements.

Validate Ruby record metadata and arity, dictionaries, indexed collection envelopes, key identity and agreement between lookup and ordered storage. Check builtin scalar wire framing and fields against the supported profile. For application codecs, check identifier and payload framing and allow unknown codec IDs. Treat the payload contents as opaque. Portable tagged byte contents are also opaque. Read reachable byte extents incrementally. Validate the captured root trailer checksum and every checksum defined by a reachable page layout. Ordinary byte records have no general payload checksum.

For sequential, offset-directory, fixed-stride and padded pages, check schema, expected row count, framing of every row, each cell and the applicable offsets, padding and checksum. A test must change a cell outside the first row and recompute the checksum. Verification must still reject that page.

## Resource limits

Use an explicit traversal stack. Advance children incrementally. Check declared sizes against the captured boundary and format limits before allocating. Read byte values in chunks of at most 64 KiB. Bound retained traversal frames, completed-reference state, diagnostic paths and scalar decoding buffers independently of file size. Stream large opaque payloads. If a valid input needs more resources than configured, report an incomplete verification with the exhausted limit. Never return success after dropping a check. The builder may select documented finite defaults and an internal mechanism for exercising each limit. Version one requires neither temporary disk storage nor public tuning options.

## Acceptance

Exercise the public method on supported portable and Ruby files, shared structures, a virtual empty root, large byte values and unknown codecs. Include every Ruby page layout. Test read-only permissions, missing paths and byte-for-byte preservation on success and failure. Append a commit during a scan and check that the result still describes the original boundary.

Use malformed fixtures to exercise the structural checks, including invalid child references, cycles, inconsistent counts, invalid codec envelopes and rechecksummed malformed cells. Check error class and location. Demonstrate that damage confined to an earlier, unshared value is outside the scan. Exercise resource exhaustion separately from corruption and show that bounded reads and traversal terminate. Document the coverage and error contract with the public API and its type signatures.

The dedicated traversal and first-defect behavior are agreed. The Ruby API, result fields, supported-profile policy and resource-limit behavior are proposed design choices. The builder owns internal class boundaries, reader reuse, numeric defaults and fixture construction.
