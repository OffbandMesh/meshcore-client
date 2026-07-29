// Trigger a browser download of `content` as `fileName`. Web only; the native
// stub is a no-op and is never reached (callers guard with `kIsWeb`). #433
export 'log_web_download_stub.dart'
    if (dart.library.js_interop) 'log_web_download_web.dart';
