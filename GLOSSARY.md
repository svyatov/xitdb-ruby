# xitdb

Terms for stored values and their interpretation in xitdb.

## Language

**Byte value**:
An xitdb value containing a sequence of bytes with an optional format tag. Its bytes have no imposed text encoding.

**Byte storage**:
The physical representation of byte values, independent of the profile that interprets their contents.

**Format tag**:
A two-byte label associated with a byte value. Its interpretation belongs to the reader of that value.
