# Ruby profile version 5 wire contract

The file header uses hash identifier `rb05` and hash size 32. Version 5 extends the [version 4 wire contract](ruby-profile-v4.md) with fixed-width row pages. Ruby handles reject files from earlier profile versions.

When all encoded rows on a page have the same byte length, the encoder writes `XF01` magic, the indexed page schema, the row payload, and the usual 32-byte SHA-256 checksum. It omits the offset directory. The page size and row count limits also apply to this layout.

The reader divides the row payload length by the row count to obtain the stride and rejects a nonzero remainder. Row `i` starts at byte `i * stride` within the payload. Each decoded row must consume exactly one stride. Empty maps have a zero-byte stride.

For variable-width rows, the writer pads every row to the longest encoded row when the padding takes fewer bytes than the `XR01` offset directory. Otherwise it writes the directory. If the smaller indexed page exceeds the byte limit, the writer can use the existing sequential page or general collection layout.

Padded pages use `XA01` magic and the same stride calculation as `XF01`. Zero bytes fill the gap between the final cell and the stride boundary. The reader rejects nonzero padding or a cell that crosses the boundary of an accessed row.

All page layouts encode integers from -64 through 63 in one byte. The tag equals the integer plus 128, giving tags 64 through 191 with no payload. Other integers use tag 3 and the existing zigzag payload. Readers reject tag 3 with a payload below 128 because the value has a one-byte encoding.
