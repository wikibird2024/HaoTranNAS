/// Joins and splits incoming TCP chunks into whole frames
/// (lengthBytes u32 BE, type u16 BE, requestId u32 BE, payload).
///
/// Rejects a lengthBytes below `minFrameLengthBytes` or above
/// `maxFrameLengthBytes` before buffering it, so a bad peer cannot make
/// the phone allocate a huge buffer. Pure: no sockets.
///
/// Skeleton: no logic yet.
library;
