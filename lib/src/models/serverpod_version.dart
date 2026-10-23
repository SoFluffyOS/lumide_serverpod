/// The version of the installed Serverpod CLI.
class ServerpodVersion {
  const ServerpodVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// Serverpod 4 added `serverpod start`, which generates code, starts
  /// Docker or the embedded database, and runs the server with hot reload.
  bool get supportsStart => major >= 4;

  /// The version printed by `serverpod version`, such as
  /// `Serverpod version: 4.0.4`, or null when [output] has none.
  static ServerpodVersion? parse(String output) {
    final match = _versionPattern.firstMatch(output);
    if (match == null) return null;
    final major = int.tryParse(match.group(1) ?? '');
    final minor = int.tryParse(match.group(2) ?? '');
    final patch = int.tryParse(match.group(3) ?? '');
    if (major == null || minor == null || patch == null) return null;
    return ServerpodVersion(major, minor, patch);
  }

  static final _versionPattern =
      RegExp(r'Serverpod version:\s*(\d+)\.(\d+)\.(\d+)');

  @override
  String toString() => '$major.$minor.$patch';
}
