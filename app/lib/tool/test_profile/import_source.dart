// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:buffer/buffer.dart';
import 'package:http/http.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import '../../shared/urls.dart' as urls;

import 'models.dart';
import 'resolver.dart' as resolver;

final _autoGeneratedImportSource = _AutoGeneratedImportSource();

/// Interface for resolving and getting data for profiles.
abstract class ImportSource {
  /// Resolve all the package-version required for the [profile].
  Future<List<ResolvedVersion>> resolveVersions(TestProfile profile);

  /// Gets the archive bytes for [package]-[version].
  Future<List<int>> getArchiveBytes(String package, String version);

  /// Close resources that were opened during the sourcing of data.
  Future<void> close();

  /// Creates a source that resolves and downloads data from pub.dev.
  static ImportSource fromPubDev({
    String? archiveCachePath,
  }) {
    archiveCachePath ??= p.join('.dart_tool', 'pub-test-profile', 'archives');
    return _PubDevImportSource(archiveCachePath: archiveCachePath);
  }

  /// Creates a source that generates data based on random seed, without any
  /// network (or file) access.
  static ImportSource autoGenerated() => _autoGeneratedImportSource;
}

/// Resolves and downloads data from pub.dev.
class _PubDevImportSource implements ImportSource {
  final String archiveCachePath;
  final _client = Client();

  _PubDevImportSource({
    required this.archiveCachePath,
  });

  @override
  Future<List<ResolvedVersion>> resolveVersions(TestProfile profile) =>
      resolver.resolveVersions(_client, profile);

  @override
  Future<List<int>> getArchiveBytes(String package, String version) async {
    final archiveName = '$package-$version.tar.gz';
    final file = File(p.join(archiveCachePath, archiveName));
    // download package archive if not already in the cache
    if (!await file.exists()) {
      final rs = await _client.get(Uri.parse(
          '${urls.siteRoot}${urls.pkgArchiveDownloadUrl(package, version)}'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(rs.bodyBytes);
    }
    return await file.readAsBytes();
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}

/// Generates data based on random seed, without any network (or file) access.
class _AutoGeneratedImportSource implements ImportSource {
  final _archives = <String, List<int>>{};

  @override
  Future<List<ResolvedVersion>> resolveVersions(TestProfile profile) async {
    final versions = <ResolvedVersion>[];
    profile.packages.forEach((p) {
      final vs = <String>[
        if (p.versions != null) ...p.versions!,
      ];
      if (vs.isEmpty) {
        final r = Random(p.name.hashCode.abs());
        vs.add('1.${r.nextInt(5)}.${r.nextInt(10)}');
      }
      // consistent published date is calculated in reverse order
      var lastCreated = DateTime.now().toUtc();
      for (final v in vs.reversed) {
        final r = Random('${p.name}-$v'.hashCode.abs());
        final diff = Duration(
          days: r.nextInt(10),
          hours: r.nextInt(24),
          minutes: 1 + r.nextInt(59),
        );
        final created = lastCreated.subtract(diff);
        versions.add(ResolvedVersion(
          package: p.name,
          version: v,
          created: created,
        ));
        lastCreated = created;
      }
    });
    return versions;
  }

  @override
  Future<List<int>> getArchiveBytes(String package, String version) async {
    final key = '$package/$version';
    if (_archives.containsKey(key)) {
      return _archives[key]!;
    }
    final archive = ArchiveBuilder();
    final hasHomepage = !version.contains('nohomepage');

    final isFlutter = package.startsWith('flutter_');
    final pubspec = json.encode({
      'name': package,
      'version': version,
      'description': '$package is awesome',
      if (hasHomepage) 'homepage': 'https://$package.example.dev/',
      'environment': {
        'sdk': '>=2.6.0 <3.0.0',
      },
      'dependencies': {
        if (isFlutter) 'flutter': {'sdk': 'flutter'},
      },
    });
    archive.addFile('pubspec.yaml', pubspec);
    archive.addFile('README.md', '# $package\n\nAwesome package.');
    archive.addFile('CHANGELOG.md', '## $version\n\n- updated');
    archive.addFile('lib/$package.dart', 'main() {\n  print(\'Hello.\');\n}\n');
    archive.addFile(
        'example/example.dart', 'main() {\n  print(\'example\');\n}\n');
    archive.addFile('LICENSE', 'All rights reserved.');
    final content = await archive.toTarGzBytes();
    _archives[key] = content;
    return content;
  }

  @override
  Future<void> close() async {}
}

@visibleForTesting
class ArchiveBuilder {
  final _entries = <TarEntry>[];

  void addFile(String path, String content) {
    final bytes = utf8.encode(content);
    _entries.add(TarEntry(
      TarHeader(
        name: path,
        size: bytes.length,
      ),
      Stream<List<int>>.fromIterable([bytes]),
    ));
  }

  Future<List<int>> toTarGzBytes() async {
    final stream = Stream<TarEntry>.fromIterable(_entries)
        .transform(tarWriter)
        .transform(gzip.encoder);
    return readAsBytes(stream);
  }
}
