// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:http/http.dart';
import 'package:pub_dev/shared/configuration.dart';
import 'package:pub_dev/tool/test_profile/models.dart';
import 'package:pub_dev/tool/test_profile/normalizer.dart';
import 'package:pub_dev/tool/test_profile/resolver.dart';
import 'package:test/test.dart';

import '../../shared/utils.dart';

void main() {
  Future<List<ResolvedVersion>> _resolve(List<TestPackage> packages) async {
    final client = Client();
    final profile = normalize(TestProfile(
      publishers: [],
      packages: packages,
      users: [],
      defaultUser: 'dev@example.com',
    ));
    final rs = await resolveVersions(client, profile);
    client.close();
    rs.sort();
    return rs;
  }

  group('resolver tests', () {
    scopedTest('latest version', () async {
      registerActiveConfiguration(Configuration.test());
      final pvs = await _resolve([TestPackage(name: 'retry')]);
      expect(pvs, hasLength(1));
      expect(pvs.first.package, 'retry');
    });

    scopedTest('dependencies', () async {
      registerActiveConfiguration(Configuration.test());
      final pvs = await _resolve([
        TestPackage(
          name: 'safe_url_check',
          versions: [TestVersion(version: '1.0.0')],
        )
      ]);
      expect(pvs, hasLength(2));
      expect(pvs[0].package, 'safe_url_check');
      expect(pvs[0].version, '1.0.0');
      // the latest version of retry has been updated after safe_url_check 1.0.0
      expect(pvs[1].package, 'retry');
    });
  });
}
