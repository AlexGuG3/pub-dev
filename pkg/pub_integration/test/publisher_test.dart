// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_integration/script/publisher.dart';
import 'package:pub_integration/src/fake_credentials.dart';
import 'package:pub_integration/src/fake_pub_server_process.dart';
import 'package:test/test.dart';

void main() {
  group('publisher', () {
    late FakePubServerProcess fakePubServerProcess;
    final httpClient = http.Client();

    setUpAll(() async {
      fakePubServerProcess = await FakePubServerProcess.start();
      await fakePubServerProcess.started;
    });

    tearDownAll(() async {
      await fakePubServerProcess.kill();
      httpClient.close();
    });

    test('publisher script', () async {
      final inviteUrlLogLineFuture = fakePubServerProcess
          .waitForLine((line) => line.contains('https://pub.dev/consent?id='));

      Future<void> inviteCompleterFn() async {
        final inviteUrlLogLine =
            await inviteUrlLogLineFuture.timeout(Duration(seconds: 30));
        final inviteUri = Uri.parse(inviteUrlLogLine
            .substring(inviteUrlLogLine.indexOf('https://pub.dev/consent')));
        final consentId = inviteUri.queryParameters['id'];

        // spoofed consent, trying to accept it with a different user
        final rs1 = await httpClient.put(
          Uri.parse(
              'http://localhost:${fakePubServerProcess.port}/api/account/consent/$consentId'),
          headers: {
            'Authorization':
                'Bearer somebodyelse-at-example-dot-org?aud=fake-site-audience',
            'content-type': 'application/json; charset="utf-8"',
          },
          body: json.encode({'granted': true}),
        );
        if (rs1.statusCode != 400) {
          throw Exception('Expected status code 400, got: ${rs1.statusCode}');
        }

        // accepting it with the good user
        final rs2 = await httpClient.put(
          Uri.parse(
              'http://localhost:${fakePubServerProcess.port}/api/account/consent/$consentId'),
          headers: {
            'Authorization':
                'Bearer dev-at-example-dot-org?aud=fake-site-audience',
            'content-type': 'application/json; charset="utf-8"',
          },
          body: json.encode({'granted': true}),
        );
        if (rs2.statusCode != 200) {
          throw Exception('Expected status code 200, got: ${rs2.statusCode}');
        }
      }

      final script = PublisherScript(
        pubHostedUrl: 'http://localhost:${fakePubServerProcess.port}',
        credentialsFileContent: fakeCredentialsFileContent(),
        invitedEmail: 'dev@example.org',
        inviteCompleterFn: inviteCompleterFn,
      );
      await script.verify();
    });
  }, timeout: Timeout.factor(testTimeoutFactor));
}
