// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'text_utils.dart';

/// Represents an evaluated score as an {id: score} map.
class Score {
  final Map<String, double> _values;

  Score(this._values);
  Score.empty() : _values = const <String, double>{};

  late final bool isEmpty = _values.isEmpty;
  late final bool isNotEmpty = !isEmpty;

  Set<String> getKeys({bool Function(String key)? where}) =>
      _values.keys.where((e) => where == null || where(e)).toSet();
  late final double maxValue = _values.values.fold(0.0, math.max);
  Map<String, double> getValues() => _values;
  bool containsKey(String key) => _values.containsKey(key);
  late final int length = _values.length;

  double operator [](String key) => _values[key] ?? 0.0;

  /// Calculates the intersection of the [scores], by multiplying the values.
  static Score multiply(List<Score> scores) {
    if (scores.isEmpty) {
      return Score.empty();
    }
    if (scores.length == 1) {
      return scores.single;
    }
    if (scores.any((score) => score.isEmpty)) {
      return Score.empty();
    }
    var keys = scores.first.getValues().keys.toSet();
    for (var i = 1; i < scores.length; i++) {
      keys = keys.intersection(scores[i].getValues().keys.toSet());
    }
    if (keys.isEmpty) {
      return Score.empty();
    }
    final values = <String, double>{};
    for (final key in keys) {
      var value = scores.first.getValues()[key]!;
      for (var i = 1; i < scores.length; i++) {
        value *= scores[i].getValues()[key]!;
      }
      values[key] = value;
    }
    return Score(values);
  }

  /// Calculates the union of the [scores], by using the maximum values from
  /// the sets.
  static Score max(List<Score> scores) {
    // remove empty scores
    scores.removeWhere((s) => s.isEmpty);

    if (scores.isEmpty) {
      return Score.empty();
    }
    if (scores.length == 1) {
      return scores.single;
    }
    final keys = scores.expand((e) => e.getValues().keys).toSet();
    final result = <String, double>{};
    for (final key in keys) {
      var value = 0.0;
      for (var i = 0; i < scores.length; i++) {
        final v = scores[i].getValues()[key];
        if (v != null) {
          value = math.max(value, v);
        }
      }
      result[key] = value;
    }
    return Score(result);
  }

  /// Remove insignificant values below a certain threshold:
  /// - [fraction] of the maximum value
  /// - [minValue] as an absolute minimum filter
  Score removeLowValues({double? fraction, double? minValue}) {
    assert(minValue != null || fraction != null);
    double? threshold = minValue;
    if (fraction != null) {
      final double fractionValue = maxValue * fraction;
      threshold ??= fractionValue;
      threshold = math.max(threshold, fractionValue);
    }
    if (threshold == null) {
      return this;
    }
    final result = <String, double>{};
    for (String key in _values.keys) {
      final value = _values[key]!;
      if (value < threshold) continue;
      result[key] = value;
    }
    return Score(result);
  }

  /// Keeps the scores only for values in [keys].
  Score project(Iterable<String> keys) {
    final result = <String, double>{};
    for (String key in keys) {
      final value = _values[key];
      if (value == null) continue;
      result[key] = value;
    }
    return Score(result);
  }

  /// Transfer the score values with [f].
  Score map(double Function(String key, double value) f) {
    final result = <String, double>{};
    for (String key in _values.keys) {
      result[key] = f(key, _values[key]!);
    }
    return Score(result);
  }

  /// Returns a new [Score] object with the top [count] entry.
  Score top(int count, {double? minValue}) {
    final entries = _values.entries
        .where((e) => minValue == null || e.value >= minValue)
        .toList();
    entries.sort((a, b) => -a.value.compareTo(b.value));
    return Score(Map.fromEntries(entries.take(count)));
  }
}

/// The weighted tokens used for the final search.
class TokenMatch {
  final Map<String, double> _tokenWeights = <String, double>{};
  double? _maxWeight;

  double? operator [](String token) => _tokenWeights[token];

  void operator []=(String token, double weight) {
    _tokenWeights[token] = weight;
    _maxWeight = null;
  }

  Iterable<String> get tokens => _tokenWeights.keys;

  double get maxWeight =>
      _maxWeight ??= _tokenWeights.values.fold<double>(0.0, math.max);

  Map<String, double> get tokenWeights => _tokenWeights;

  void addWithMaxValue(String token, double weight) {
    final old = _tokenWeights[token] ?? 0.0;
    if (old < weight) {
      _tokenWeights[token] = weight;
    }
  }
}

/// Stores a token -> documentId inverted index with weights.
class TokenIndex {
  /// {id: hash} map to detect if a document update or removal is a no-op.
  final _textHashes = <String, String>{};

  /// Maps token Strings to a weighted map of document ids.
  final _inverseIds = <String, Map<String, double>>{};

  /// {id: size} map to store a value representative to the document length
  final _docSizes = <String, double>{};

  /// The number of tokens stored in the index.
  int get tokenCount => _inverseIds.length;

  int get documentCount => _docSizes.length;

  void add(String id, String? text) {
    if (text == null) return;
    final tokens = tokenize(text);
    if (tokens == null || tokens.isEmpty) {
      if (_textHashes.containsKey(id)) {
        remove(id);
      }
      return;
    }
    final String textHash = '${text.hashCode}/${tokens.length}';
    if (_textHashes.containsKey(id) && _textHashes[id] != textHash) {
      remove(id);
    }
    for (String token in tokens.keys) {
      final Map<String, double> weights =
          _inverseIds.putIfAbsent(token, () => <String, double>{});
      weights[id] = math.max(weights[id] ?? 0.0, tokens[token]!);
    }
    // Document size is a highly scaled-down proxy of the length.
    final docSize = 1 + math.log(1 + tokens.length) / 100;
    _docSizes[id] = docSize;
    _textHashes[id] = textHash;
  }

  void remove(String id) {
    _textHashes.remove(id);
    _docSizes.remove(id);
    final List<String> removeTokens = [];
    _inverseIds.forEach((String key, Map<String, double> weights) {
      weights.remove(id);
      if (weights.isEmpty) removeTokens.add(key);
    });
    removeTokens.forEach(_inverseIds.remove);
  }

  /// Match the text against the corpus and return the tokens or
  /// their partial segments that have match.
  @visibleForTesting
  TokenMatch lookupTokens(String text) {
    final tokenMatch = TokenMatch();

    for (final word in splitForIndexing(text)) {
      final tokens = tokenize(word, isSplit: true) ?? {};

      final present = tokens.keys
          .where((token) => (_inverseIds[token]?.length ?? 0) > 0)
          .toList();
      if (present.isEmpty) {
        return TokenMatch();
      }
      final bestTokenValue =
          present.map((token) => tokens[token]!).reduce(math.max);
      final minTokenValue = bestTokenValue * 0.7;
      for (final token in present) {
        final value = tokens[token]!;
        if (value >= minTokenValue) {
          tokenMatch.addWithMaxValue(token, value);
        }
      }
    }

    return tokenMatch;
  }

  /// Returns an {id: score} map of the documents stored in the [TokenIndex].
  /// The tokens in [tokenMatch] will be used to calculate a weighted sum of scores.
  ///
  /// When [limitToIds] is specified, the result will contain only the set of
  /// identifiers in it.
  Map<String, double> _scoreDocs(TokenMatch tokenMatch,
      {double weight = 1.0, int wordCount = 1, Set<String>? limitToIds}) {
    // Summarize the scores for the documents.
    final Map<String, double> docScores = <String, double>{};
    for (String token in tokenMatch.tokens) {
      final docWeights = _inverseIds[token]!;
      for (String id in docWeights.keys) {
        if (limitToIds != null && !limitToIds.contains(id)) continue;
        final double prevValue = docScores[id] ?? 0.0;
        final double currentValue = tokenMatch[token]! * docWeights[id]!;
        docScores[id] = math.max(prevValue, currentValue);
      }
    }

    // In multi-word queries we will penalize the score with the document size
    // for each word separately. As these scores will be mulitplied, we need to
    // compensate the formula in order to prevent multiple exponential penalties.
    final double wordSizeExponent = 1.0 / wordCount;

    // post-process match weights
    for (String id in docScores.keys.toList()) {
      double docSize = _docSizes[id]!;
      if (wordCount > 1) {
        docSize = math.pow(docSize, wordSizeExponent).toDouble();
      }
      docScores[id] = weight * docScores[id]! / docSize;
    }
    return docScores;
  }

  /// Search the index for [text], with a (term-match / document coverage percent)
  /// scoring.
  @visibleForTesting
  Map<String, double> search(String text) {
    return _scoreDocs(lookupTokens(text));
  }

  /// Search the index for [words], with a (term-match / document coverage percent)
  /// scoring.
  Score searchWords(List<String> words,
      {double weight = 1.0, Set<String>? limitToIds}) {
    if (limitToIds != null && limitToIds.isEmpty) {
      return Score.empty();
    }
    final scores = <Score>[];
    for (final w in words) {
      final tokens = lookupTokens(w);
      final values = _scoreDocs(
        tokens,
        weight: weight,
        wordCount: words.length,
        limitToIds: limitToIds,
      );
      if (values.isEmpty) {
        return Score.empty();
      }
      scores.add(Score(values));
    }
    return Score.multiply(scores);
  }
}
