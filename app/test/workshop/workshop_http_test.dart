import 'dart:async';
import 'dart:io';

import 'package:dsh_app/workshop/workshop_http.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _OpeningClient implements HttpClient {
  final opening = Completer<HttpClientRequest>();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => opening.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  var aborted = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #abort) { aborted = true; return null; }
    if (invocation.memberName == #headers) throw StateError('synthetic header failure');
    return null;
  }
}

void main() {
  test('an openUrl result arriving after timeout is aborted', () async {
    final client = _OpeningClient(), request = _Request();
    final http = IoWorkshopHttp(workshopTestOrigin, client: client);
    addTearDown(http.close);
    await expectLater(http.get(workshopTestOrigin.resolve('/market/workshop.json'), timeout: Duration.zero), throwsA(isA<TimeoutException>()));
    client.opening.complete(request);
    await Future<void>.delayed(Duration.zero);
    expect(request.aborted, isTrue);
  });

  test('a synchronous header failure aborts the acquired request', () async {
    final client = _OpeningClient(), request = _Request();
    client.opening.complete(request);
    final http = IoWorkshopHttp(workshopTestOrigin, client: client);
    addTearDown(http.close);
    await expectLater(http.get(workshopTestOrigin.resolve('/market/workshop.json')), throwsA(isA<StateError>()));
    expect(request.aborted, isTrue);
  });
}
