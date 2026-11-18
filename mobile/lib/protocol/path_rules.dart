/// Checks a backup path before it goes on the wire: UTF-8 length
/// (`maxPathBytes`), number of parts (`maxPathComponents`), part length
/// (`maxNameBytes`), no empty, `.` or `..` parts. Same rules as the
/// server, so the phone fails early with a clear reason.
///
/// Skeleton: no logic yet.
library;
