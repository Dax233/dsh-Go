import 'dart:async';
import 'dart:io';

import '../update/update_http.dart';
import 'workshop_models.dart';

/// Public downloads and authenticated API calls share this no-redirect
/// transport. A test can replace it without opening a network connection.
abstract class WorkshopHttp implements UpdateHttp {
  Future<UpdateHttpResponse> request(String method, Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Duration timeout = const Duration(seconds: 30),
  });
  @override
  Future<UpdateHttpResponse> get(Uri url, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 15)}) =>
      request('GET', url, headers: headers, timeout: timeout);
  void close() {}
}

class IoWorkshopHttp extends WorkshopHttp {
  IoWorkshopHttp(Uri origin, {HttpClient? client}) : origin = workshopOrigin(origin), _client = (client ?? HttpClient())
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 5)
    ..autoUncompress = false
    ..userAgent = 'dsh-app-workshop';

  final Uri origin;
  final HttpClient _client;

  @override
  Future<UpdateHttpResponse> request(String method, Uri url, {Map<String, String> headers = const {}, List<int>? body, Duration timeout = const Duration(seconds: 30)}) async {
    if (url.origin != origin.origin || url.userInfo.isNotEmpty || url.hasFragment) workshopInvalid('workshop_untrusted_origin');
    var abandoned = false;
    HttpClientRequest? request;
    try {
      final opened = await _client.openUrl(method, url).then((value) {
        // Future.timeout does not cancel openUrl. A late connection must not
        // keep an abandoned request/socket alive after the caller has failed.
        if (abandoned) value.abort();
        return value;
      }).timeout(timeout, onTimeout: () {
        abandoned = true;
        throw TimeoutException('workshop_timeout');
      });
      request = opened;
      opened.followRedirects = false;
      opened.headers.set('accept-encoding', 'identity');
      headers.forEach(opened.headers.set);
      if (body != null) {
        opened.contentLength = body.length;
        opened.add(body);
      }
      final response = await opened.close().timeout(timeout);
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) => responseHeaders[name.toLowerCase()] = values.join(', '));
      return UpdateHttpResponse(status: response.statusCode, headers: responseHeaders,
        contentLength: response.contentLength >= 0 ? response.contentLength : null, body: response);
    } on Object {
      abandoned = true;
      request?.abort();
      rethrow;
    }
  }
  @override
  void close() => _client.close(force: true);
}
