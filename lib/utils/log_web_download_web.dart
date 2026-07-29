import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Trigger a browser download of [content] (UTF-8 text) as [fileName] by
/// creating an in-memory Blob and clicking a transient anchor. #433
void downloadTextFile(String fileName, String content) {
  final blob = web.Blob(
    <JSAny>[content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName;
  anchor.click();
  web.URL.revokeObjectURL(url);
}
