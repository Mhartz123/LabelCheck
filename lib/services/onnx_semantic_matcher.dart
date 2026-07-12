import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import 'bert_tokenizer.dart';

/// The nearest FDA-advisory ("warned") product name that a scanned label's
/// OCR text matched semantically, with the cosine similarity that earned it.
class SemanticMatch {
  final String productName;
  final double score;

  const SemanticMatch({required this.productName, required this.score});
}

/// On-device ONNX **semantic matcher** (retriever), the removable bottom tier
/// of the compliance cascade. It encodes OCR'd label text into a sentence
/// embedding with a fine-tuned DistilBERT (INT8 ONNX), then returns the
/// nearest product name from the precomputed FDA advisory embedding index by
/// cosine similarity. It does NOT classify — a hit means the scanned text is
/// closest to a *warned* product, i.e. flagged/non-compliant.
///
/// Pipeline (must mirror how the index was built, or matching silently breaks):
///   normalizeKey(text) → WordPiece (uncased, vocab.json) → model →
///   mean-pool last_hidden_state over the attention mask → L2-normalize →
///   dot-product against the (already L2-normalized) index rows.
///
/// KNOWN ISSUE: the shipped `model_qint8_arm64.onnx` benchmarks ~1% Recall@1.
/// Standalone verification showed its embeddings are *collapsed* (mean pairwise
/// cosine ≈ 0.99 across the whole index), so with any low [_similarityFloor]
/// this tier matches — and therefore flags — almost every scan. This is a
/// training/export defect, not a wiring bug; the tier is behind
/// `ComplianceEngine._semanticMatcherEnabled` so it stays trivially removable
/// until the model is retrained and re-verified.
class OnnxSemanticMatcher {
  static const String _modelAsset = 'assets/model_qint8_arm64.onnx';
  static const String _embeddingsAsset = 'assets/fda_index_embeddings_fp16.npy';
  static const String _namesAsset = 'assets/fda_index_names.txt';

  static const int _sequenceLength = 64;
  static const int _embeddingDim = 768;

  /// Minimum cosine similarity for the nearest index entry to count as a
  /// confident match. This is the value a *healthy* model wants; the current
  /// collapsed model (see class doc) exceeds it on nearly everything, so it
  /// must be re-tuned once the model is fixed.
  static const double _similarityFloor = 0.90;

  static final RegExp _nonKeyChars = RegExp(r'[^A-Z0-9 ]');
  static final RegExp _whitespace = RegExp(r'\s+');

  static Future<OnnxSemanticMatcher>? _loading;

  final OrtSession _session;
  final BertTokenizer _tokenizer;

  /// Flat [count] × [_embeddingDim] index, each row already L2-normalized.
  final Float32List _index;

  /// Product display names aligned row-for-row with [_index].
  final List<String> _names;
  final int _count;

  OnnxSemanticMatcher._(
    this._session,
    this._tokenizer,
    this._index,
    this._names,
    this._count,
  );

  /// Loads the model, tokenizer, and embedding index once; subsequent calls
  /// reuse the same in-flight/completed load.
  static Future<OnnxSemanticMatcher> instance() => _loading ??= _load();

  static Future<OnnxSemanticMatcher> _load() async {
    OrtEnv.instance.init();

    final tokenizer = await BertTokenizer.loadFromAsset();

    final modelBytes =
        (await rootBundle.load(_modelAsset)).buffer.asUint8List();
    final session = OrtSession.fromBuffer(modelBytes, OrtSessionOptions());

    final names = await _loadNames();
    final index = await _loadIndex(names.length);

    return OnnxSemanticMatcher._(
      session,
      tokenizer,
      index,
      names,
      names.length,
    );
  }

  /// Returns the nearest FDA-advisory product name for [text], or null if the
  /// best cosine similarity is below [_similarityFloor].
  SemanticMatch? match(String text) {
    final normalized = _normalizeKey(text);
    if (normalized.isEmpty) return null;

    final query = _embed(normalized);

    var bestScore = -2.0;
    var bestIdx = -1;
    for (var r = 0; r < _count; r++) {
      final base = r * _embeddingDim;
      var dot = 0.0;
      for (var d = 0; d < _embeddingDim; d++) {
        dot += _index[base + d] * query[d];
      }
      if (dot > bestScore) {
        bestScore = dot;
        bestIdx = r;
      }
    }

    if (bestIdx < 0 || bestScore < _similarityFloor) return null;
    return SemanticMatch(productName: _names[bestIdx], score: bestScore);
  }

  /// Normalizes query text the same way the index `name_key`s were built:
  /// uppercase → non-`[A-Z0-9 ]` to space → collapse whitespace → trim.
  static String _normalizeKey(String text) {
    return text
        .toUpperCase()
        .replaceAll(_nonKeyChars, ' ')
        .replaceAll(_whitespace, ' ')
        .trim();
  }

  /// Encodes [normalizedText], runs the model, mean-pools over the attention
  /// mask, and L2-normalizes to a single query vector.
  Float32List _embed(String normalizedText) {
    final tokenized =
        _tokenizer.encode(normalizedText, sequenceLength: _sequenceLength);

    // ONNX inputs are int64; the tokenizer emits int32.
    final ids = Int64List(_sequenceLength);
    final mask = Int64List(_sequenceLength);
    for (var i = 0; i < _sequenceLength; i++) {
      ids[i] = tokenized.inputIds[i];
      mask[i] = tokenized.attentionMask[i];
    }

    final idsTensor =
        OrtValueTensor.createTensorWithDataList(ids, [1, _sequenceLength]);
    final maskTensor =
        OrtValueTensor.createTensorWithDataList(mask, [1, _sequenceLength]);
    final runOptions = OrtRunOptions();

    List<OrtValue?> outputs;
    try {
      outputs = _session.run(
        runOptions,
        {'input_ids': idsTensor, 'attention_mask': maskTensor},
        const ['last_hidden_state'],
      );
    } finally {
      idsTensor.release();
      maskTensor.release();
      runOptions.release();
    }

    // last_hidden_state: [1, seq, 768].
    final hidden = (outputs[0]!.value as List)[0] as List;

    final pooled = Float32List(_embeddingDim);
    var maskCount = 0.0;
    for (var t = 0; t < _sequenceLength; t++) {
      if (tokenized.attentionMask[t] == 0) continue;
      maskCount += 1;
      final row = hidden[t] as List;
      for (var d = 0; d < _embeddingDim; d++) {
        pooled[d] += (row[d] as num).toDouble();
      }
    }

    for (final output in outputs) {
      output?.release();
    }

    if (maskCount == 0) maskCount = 1;
    var norm = 0.0;
    for (var d = 0; d < _embeddingDim; d++) {
      pooled[d] /= maskCount;
      norm += pooled[d] * pooled[d];
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var d = 0; d < _embeddingDim; d++) {
        pooled[d] /= norm;
      }
    }
    return pooled;
  }

  static Future<List<String>> _loadNames() async {
    final raw = await rootBundle.loadString(_namesAsset);
    final lines = raw.split('\n').map((l) => l.trimRight()).toList();
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  /// Parses the `.npy` float16 embedding index into a flat, row-normalized
  /// [Float32List]. The index rows already have unit norm, but we don't rely
  /// on that — cosine here is a plain dot product against L2-normalized rows.
  static Future<Float32List> _loadIndex(int expectedRows) async {
    final data = await rootBundle.load(_embeddingsAsset);

    // .npy header: magic(6) + version(2) + headerLen(2 for v1, 4 for v2+).
    final major = data.getUint8(6);
    final int dataOffset;
    if (major >= 2) {
      dataOffset = 12 + data.getUint32(8, Endian.little);
    } else {
      dataOffset = 10 + data.getUint16(8, Endian.little);
    }

    final halfCount = (data.lengthInBytes - dataOffset) ~/ 2;
    final rows = halfCount ~/ _embeddingDim;
    if (rows != expectedRows) {
      // Names and embeddings must be line-for-line aligned; if they aren't,
      // matching would return the wrong product name for a given row.
      throw StateError(
        'FDA index row mismatch: $rows embedding rows vs $expectedRows names.',
      );
    }

    final out = Float32List(rows * _embeddingDim);
    final outBits = Uint32List.view(out.buffer);
    for (var i = 0; i < out.length; i++) {
      outBits[i] = _halfBitsToFloatBits(data.getUint16(dataOffset + i * 2, Endian.little));
    }
    return out;
  }

  /// Converts IEEE-754 half-precision bits to single-precision bits (Dart has
  /// no native float16, and rootBundle gives us the raw little-endian bytes).
  static int _halfBitsToFloatBits(int h) {
    final sign = (h & 0x8000) << 16;
    var exp = (h >> 10) & 0x1F;
    var mant = h & 0x3FF;

    if (exp == 0) {
      if (mant == 0) return sign; // ±0
      // Subnormal half → normalize into a float32 normal.
      exp = 1;
      while ((mant & 0x400) == 0) {
        mant <<= 1;
        exp--;
      }
      mant &= 0x3FF;
      return sign | ((exp + (127 - 15)) << 23) | (mant << 13);
    } else if (exp == 0x1F) {
      return sign | 0x7F800000 | (mant << 13); // ±inf / NaN
    }
    return sign | ((exp + (127 - 15)) << 23) | (mant << 13);
  }
}
