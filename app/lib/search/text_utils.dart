// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

import 'package:html/parser.dart';

import '../shared/markdown.dart';

final _separatorChars = '_.?!,;:=()<>[]{}~@#\$%&|+-*\\/"\'`';
final _escapedSeparators = _separatorChars.split('').map((s) => '\\$s').join();
final _separators = RegExp('[$_escapedSeparators]|\\s');
final RegExp _nonCharacterRegExp = RegExp('[^a-z0-9]');
final RegExp _multiWhitespaceRegExp = RegExp('\\s+');
final RegExp _exactTermRegExp = RegExp(r'"([^"]+)"');

const _commonApiSymbols = {
  'toString',
  'noSuchMethod',
  'hashCode',
  'runtimeType',
};

bool isCommonApiSymbol(String symbol) {
  if (_commonApiSymbols.contains(symbol)) {
    return true;
  }
  if (symbol.startsWith('operator ')) return true;
  return false;
}

String _compactText(String? text, {int maxLength = -1}) {
  if (text == null) return '';
  String t = text.replaceAll(_multiWhitespaceRegExp, ' ').trim();
  if (maxLength > 0 && t.length > maxLength) {
    t = t.substring(0, maxLength);
  }
  return t;
}

String compactDescription(String? text) => _compactText(text, maxLength: 500);

String compactReadme(String? text) {
  if (text == null || text.isEmpty) return '';
  final html = markdownToHtml(text)!
      .replaceAll('</li>', '\n</li>')
      .replaceAll('</p>', '\n</p>')
      .replaceAll('</ul>', '\n</ul>')
      .replaceAll('</ol>', '\n</ol>')
      .replaceAll('</dl>', '\n</dl>')
      .replaceAll('</dd>', '\n</dd>')
      .replaceAll('</pre>', '\n</pre>')
      .replaceAll('</blockquote>', '\n</blockquote>');
  final root = parseFragment(html);
  return _compactText(root.text!, maxLength: 5000);
}

String normalizeBeforeIndexing(String? text) {
  if (text == null) return '';
  final String t = text
      .toLowerCase()
      .replaceAll(_nonCharacterRegExp, ' ')
      .replaceAll(_multiWhitespaceRegExp, ' ')
      .trim();
  return t;
}

Iterable<String> splitForIndexing(String? text) {
  if (text == null || text.isEmpty) return Iterable.empty();
  return text.split(_separators).where((s) => s.isNotEmpty);
}

List<String> splitForQuery(String? text) {
  final words = splitForIndexing(text).toSet().toList();

  // lookup longer words first, as it may restrict the result set better
  words.sort((a, b) => -a.length.compareTo(b.length));

  // limit the number of words to lookup
  if (words.length > 20) {
    words.removeRange(20, words.length);
  }

  return words;
}

List<String> extractExactPhrases(String text) =>
    _exactTermRegExp.allMatches(text).map((m) => m.group(1)!).toList();

const int _maxWordLength = 80;

Map<String, double>? tokenize(String? originalText, {bool isSplit = false}) {
  if (originalText == null || originalText.isEmpty) return null;
  final tokens = <String, double>{};

  final words = isSplit ? [originalText] : splitForIndexing(originalText);
  for (String word in words) {
    if (word.length > _maxWordLength) {
      continue;
    }

    final normalizedWord = normalizeBeforeIndexing(word);
    if (normalizedWord.isEmpty) continue;

    tokens[normalizedWord] = 1.0;

    // Scan for CamelCase phrases and extract Camel and Case separately.
    final wordCodeUnits = word.codeUnits;
    final changeIndex = <int>[0];
    bool prevLower = _isLower(wordCodeUnits[0]);
    for (int i = 1; i < word.length; i++) {
      final lower = _isLower(wordCodeUnits[i]);
      if (!lower && prevLower) {
        changeIndex.add(i);
      }
      prevLower = lower;
    }
    changeIndex.add(word.length);
    for (int i = 1; i < changeIndex.length; i++) {
      final token = normalizeBeforeIndexing(
          word.substring(changeIndex[i - 1], changeIndex[i]));
      final weight = math.pow((token.length / word.length), 0.5).toDouble();
      if ((tokens[token] ?? 0.0) < weight) {
        tokens[token] = weight;
      }
    }
  }
  return tokens;
}

final _upperA = 'A'.codeUnits.single;
final _upperZ = 'Z'.codeUnits.single;
bool _isLower(int c) => c < _upperA || _upperZ < c;

/// Generates the N-grams of [input], which are continuous character strings of
/// length between [minLength] and [maxLength] (both inclusive).
/// Eg. abc -> ab, bc
Set<String> ngrams(String input, int minLength, int maxLength) {
  final ngrams = <String>{};
  for (int length = minLength; length <= maxLength; length++) {
    if (input.length >= length) {
      for (int i = 0; i <= input.length - length; i++) {
        ngrams.add(input.substring(i, i + length));
      }
    }
  }
  return ngrams;
}
