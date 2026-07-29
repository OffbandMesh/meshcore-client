import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Trigger a browser download of [content] (UTF-8 text) as [fileName] by
/// creating an in-memory Blob and clicking a transient anchor. #433
///
/// The anchor is appended to the document before clicking (Firefox ignores
/// `click()` on a disconnected anchor) and the object URL is revoked on a delay
/// (revoking synchronously can abort the download in Safari/iOS).
void downloadTextFile(String fileName, String content) {
  final blob = web.Blob(
    <JSAny>[content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName;
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  unawaited(
    Future<void>.delayed(
      const Duration(seconds: 10),
      () => web.URL.revokeObjectURL(url),
    ),
  );
}
