import 'dart:convert';

import 'package:html/parser.dart' show parseFragment;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../api/model/model.dart';
import '../api/model/submessage.dart';

final RegExp _blockBoundaryTagsRegExp = RegExp(
  r'<\s*(?:br\b[^>]*/?|hr\b[^>]*/?|/(?:p|div|li|ul|ol|blockquote|pre|h[1-6]|tr|td|th|table|section|article|header|footer)\s*)>',
  caseSensitive: false,
);
final RegExp _whitespaceRunRegExp = RegExp(r'\s+');
final RegExp _latinCombiningMarksRegExp = RegExp(
  r'(\p{Script=Latin})[\u0300-\u036f]+',
  unicode: true,
);
final RegExp _strokedLatinRegExp = RegExp(r'[øłđħŧı]');
const Map<String, String> _strokedLatinReplacements = {
  'ø': 'o',
  'ł': 'l',
  'đ': 'd',
  'ħ': 'h',
  'ŧ': 't',
  'ı': 'i',
};
final RegExp _nonTokenCharsRegExp = RegExp(
  r'[^\p{L}\p{N}\p{M}\p{Co}]+',
  unicode: true,
);

String _collapseWhitespace(String text) {
  if (text.isEmpty) return '';
  return text.replaceAll(_whitespaceRunRegExp, ' ').trim();
}

String _joinNonEmpty(String a, String b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  return '$a $b';
}

/// Extract searchable plain text from rendered message HTML.
///
/// Inserts spaces before block-level closing tags and line-break tags so
/// adjacent blocks do not concatenate across boundaries, then decodes entities
/// via the HTML fragment parser and normalizes whitespace.
String extractPlainTextFromHtml(String html) {
  if (html.isEmpty) return '';
  final spaced = html.replaceAllMapped(
    _blockBoundaryTagsRegExp,
    (match) => ' ${match[0]}',
  );
  final extracted = parseFragment(spaced).text ?? '';
  return _collapseWhitespace(extracted);
}

/// Mirror [Poll.fromSubmessages] defensively to extract the searchable question
/// and option strings from raw submessage records.
String extractPollPlainText({
  required int messageSenderId,
  required Iterable<({int senderId, String content})> submessages,
}) {
  final iterator = submessages.iterator;
  if (!iterator.moveNext()) return '';

  final first = iterator.current;
  final WidgetData widgetData;
  try {
    widgetData = WidgetData.fromJson(jsonDecode(first.content));
  } catch (_) {
    return '';
  }
  if (widgetData is! PollWidgetData) return '';

  const maxIdx = 1000;
  String question = widgetData.extraData.question;
  final options = <String>[];
  final existingOptionTexts = <String>{};
  final seenKeys = <String>{};

  void addOption({required int? senderId, required int idx, required String option}) {
    if (idx > maxIdx || idx < 0) return;
    if (existingOptionTexts.contains(option)) return;
    final key = PollEventSubmessage.optionKey(senderId: senderId, idx: idx);
    if (!seenKeys.add(key)) return;
    options.add(option);
    existingOptionTexts.add(option);
  }

  final initialOptions = widgetData.extraData.options;
  for (int i = 0; i < initialOptions.length; i++) {
    addOption(senderId: null, idx: i, option: initialOptions[i]);
  }

  while (iterator.moveNext()) {
    final sub = iterator.current;
    final PollEventSubmessage pollEvent;
    try {
      pollEvent = PollEventSubmessage.fromJson(
        jsonDecode(sub.content) as Map<String, Object?>,
      );
    } catch (_) {
      continue;
    }
    switch (pollEvent) {
      case PollNewOptionEventSubmessage(:final option, :final idx):
        addOption(senderId: sub.senderId, idx: idx, option: option);
      case PollQuestionEventSubmessage(question: final newQuestion):
        if (sub.senderId == messageSenderId) {
          question = newQuestion;
        }
      case PollVoteEventSubmessage():
      case UnknownPollEventSubmessage():
        break;
    }
  }

  return _collapseWhitespace([question, ...options].join(' '));
}

/// Extract searchable plain text combining rendered HTML and poll widget text
/// from stored message records.
String extractMessageSearchBodyText({
  required String htmlContent,
  required int messageSenderId,
  Iterable<({int senderId, String content})> submessages = const [],
}) {
  final htmlText = extractPlainTextFromHtml(htmlContent);
  final pollText = extractPollPlainText(
    messageSenderId: messageSenderId,
    submessages: submessages,
  );
  return _joinNonEmpty(htmlText, pollText);
}

/// Extract searchable plain text from a live in-memory [Message], matching
/// [extractMessageSearchBodyText] on the corresponding stored rows.
String extractSearchBodyTextFromMessage(Message message) {
  final htmlText = extractPlainTextFromHtml(message.content);
  final poll = message.poll;
  if (poll == null) return htmlText;
  final pollText = _collapseWhitespace([
    poll.question,
    for (final option in poll.options) option.text,
  ].join(' '));
  return _joinNonEmpty(htmlText, pollText);
}

/// Lowercase and strip Latin diacritics (including stroked Latin letters folded
/// by SQLite FTS5 `unicode61 remove_diacritics 2`) while preserving non-Latin marks.
String foldForLocalSearch(String input) {
  final lower = input.toLowerCase();
  final decomposed = unorm.nfd(lower);
  final stripped = decomposed
    .replaceAllMapped(_latinCombiningMarksRegExp, (m) => m[1]!)
    .replaceAllMapped(_strokedLatinRegExp, (m) => _strokedLatinReplacements[m[0]!]!);
  return unorm.nfc(stripped);
}

/// Split [input] into NFC-normalized tokens for SQLite FTS5 `MATCH`, leaving
/// case and diacritic folding to SQLite `unicode61 remove_diacritics 2`.
List<String> tokenizeForFtsMatch(String input) {
  final normalized = unorm.nfc(input.toLowerCase());
  return [
    for (final part in normalized.split(_nonTokenCharsRegExp))
      if (part.isNotEmpty) part,
  ];
}

/// Split [input] into folded alphanumeric tokens matching word boundaries.
List<String> tokenizeForLocalSearch(String input) {
  final folded = foldForLocalSearch(input);
  return [
    for (final part in folded.split(_nonTokenCharsRegExp))
      if (part.isNotEmpty) part,
  ];
}
