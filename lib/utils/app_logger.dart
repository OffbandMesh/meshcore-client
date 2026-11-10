import '../services/app_debug_log_service.dart';

/// Global app logger instance
/// Usage: appLogger.info('Message', tag: 'MyClass');
class AppLogger {
  AppDebugLogService? _service;
  bool _enabled = false;

  /// "version+build" of the running app, stamped into the log at startup and
  /// on every connect so an exported log names the build that wrote it.
  String appVersion = 'unknown';

  /// Initialize the logger with the debug log service
  void initialize(AppDebugLogService service, {bool enabled = false}) {
    _service = service;
    _enabled = enabled;
    _service?.setEnabled(enabled);
  }

  /// Update whether logging is enabled
  void setEnabled(bool enabled) {
    _enabled = enabled;
    _service?.setEnabled(enabled);
  }

  /// Check if logging is currently enabled
  bool get isEnabled => _enabled;

  // Every message goes to the service even when the in-app log view is off:
  // the service always writes the log file that exports carry, and applies
  // the view toggle itself. Gating here dropped these lines from exports.

  /// Log an info message
  void info(String message, {String tag = 'App', bool noNotify = false}) {
    _service?.info(message, tag: tag, noNotify: noNotify);
  }

  /// Log a warning message
  void warn(String message, {String tag = 'App', bool noNotify = false}) {
    _service?.warn(message, tag: tag, noNotify: noNotify);
  }

  /// Log an error message
  void error(String message, {String tag = 'App', bool noNotify = false}) {
    _service?.error(message, tag: tag, noNotify: noNotify);
  }

  /// Log a message with custom level
  void log(
    String message, {
    String tag = 'App',
    AppDebugLogLevel level = AppDebugLogLevel.info,
    bool noNotify = false,
  }) {
    _service?.log(message, tag: tag, level: level, noNotify: noNotify);
  }
}

/// Global logger instance
final appLogger = AppLogger();
