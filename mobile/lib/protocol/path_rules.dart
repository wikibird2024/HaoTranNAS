/// Checks a backup path before it goes on the wire (spec §10): UTF-8,
/// 1 ..= `maxPathBytes` bytes, at most `maxPathComponents` parts of
/// 1 ..= 255 bytes each, no leading or trailing `/`, no empty, `.` or `..`
/// part, no NUL and no backslash. No Unicode normalization.
///
/// Same rules as the server, so the phone fails early with a clear
/// reason. Pure: no I/O.
library;

import 'dart:convert';

import 'limits.dart';
import 'wire_writer.dart' show hasLoneSurrogate;

/// Longest single path part, in UTF-8 bytes (a path rule, not a shared
/// limit constant: spec §14).
const int maxPathComponentBytes = 255;

/// Null if [path] follows the path rules, else a short reason.
String? pathProblem(String path) {
  if (path.isEmpty) return 'empty';
  if (hasLoneSurrogate(path)) return 'not valid Unicode (lone surrogate)';
  final pathBytes = utf8.encode(path).length;
  if (pathBytes > maxPathBytes) {
    return '$pathBytes bytes, longer than $maxPathBytes';
  }
  if (path.contains('\u0000')) return 'contains NUL';
  if (path.contains(r'\')) return r'contains a backslash \';
  if (path.startsWith('/')) return 'starts with /';
  if (path.endsWith('/')) return 'ends with /';
  final components = path.split('/');
  if (components.length > maxPathComponents) {
    return '${components.length} parts, more than $maxPathComponents';
  }
  for (final component in components) {
    if (component.isEmpty) return 'empty part (//)';
    if (component == '.' || component == '..') return 'part "$component"';
    final componentBytes = utf8.encode(component).length;
    if (componentBytes > maxPathComponentBytes) {
      return 'part of $componentBytes bytes, longer than '
          '$maxPathComponentBytes';
    }
  }
  return null;
}
