/// Identity of the running binary, injected at build time (#397).
///
/// Set via `--dart-define` so every build, debug or release, dev or prod,
/// carries its own identity, independent of the pubspec marketing version:
///
/// ```
/// flutter build apk --release \
///   --dart-define=GIT_SHA=$(git rev-parse --short HEAD) \
///   --dart-define=GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD) \
///   --dart-define=BUILD_TIME=$(date -u +%Y-%m-%dT%H:%MZ)
/// ```
///
/// Falls back to `dev` / `unknown` when the defines are absent, so a plain
/// `flutter run` still works and never crashes on a missing value.
class BuildInfo {
  const BuildInfo._();

  static const String gitSha = String.fromEnvironment(
    'GIT_SHA',
    defaultValue: 'dev',
  );

  static const String gitBranch = String.fromEnvironment(
    'GIT_BRANCH',
    defaultValue: 'dev',
  );

  static const String buildTime = String.fromEnvironment(
    'BUILD_TIME',
    defaultValue: 'unknown',
  );

  /// One-line stamp for the UI: `branch @ sha · built <time>`.
  static String get stamp => '$gitBranch @ $gitSha · built $buildTime';
}
