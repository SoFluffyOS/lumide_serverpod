import 'dart:async';

import 'package:lumide_api/lumide_api.dart';

/// Appends [text] to [output] without waiting; a channel Lumide already
/// closed is not an error worth reporting.
void appendQuietly(LumideOutputChannel output, String text) {
  unawaited(output.append(text).catchError((Object _) {}));
}
