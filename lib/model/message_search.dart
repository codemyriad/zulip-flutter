import '../api/model/model.dart';
import 'message_database.dart';
import 'message_search_text.dart';
import 'narrow.dart';
import 'stored_message_codec.dart';

final RegExp _operatorPrefixRegExp = RegExp(r'^[a-zA-Z-]+$');
final RegExp _asciiTokenRegExp = RegExp(r'^[a-z0-9]+$');
final RegExp _hasLinkRegExp = RegExp(
  r'''<a\b[^>]*\bhref\s*=\s*(?:["'](?!#)(?!\/#narrow)|[^\s"'>])''',
  caseSensitive: false,
);
final RegExp _hasImageRegExp = RegExp(
  r'''<img\b(?![^>]*\bclass\s*=\s*["'][^"']*\bemoji\b)|class\s*=\s*["'][^"']*\bmessage_inline_image\b''',
  caseSensitive: false,
);
final RegExp _hasAttachmentRegExp = RegExp(
  r'/user_uploads/',
  caseSensitive: false,
);

/// Read-only accessors needed to resolve search operators and evaluate message
/// visibility/muting rules for offline search.
abstract interface class MessageSearchStore {
  int get selfUserId;
  Map<int, ZulipStream> get streams;
  Map<int, Subscription> get subscriptions;
  Iterable<User> get allUsers;
  User? getUser(int userId);
  bool selfHasContentAccess(ZulipStream channel);
  bool isTopicVisible(int channelId, TopicName topic);
  bool isTopicVisibleInChannel(int channelId, TopicName topic);
  UserTopicVisibilityPolicy topicVisibilityPolicy(int channelId, TopicName topic);
  bool shouldMuteDmConversation(DmNarrow narrow);
  Set<int> get starredMessages;
  bool get isStarredMessagesAtCap;
}

final class _LexedToken {
  const _LexedToken({
    required this.raw,
    required this.negated,
    required this.hadQuotes,
    required this.unquotedColonIndex,
  });

  final String raw;
  final bool negated;
  final bool hadQuotes;
  final int? unquotedColonIndex;
}

final class _TextQueryTerm {
  const _TextQueryTerm({
    required this.text,
    required this.isQuoted,
    required this.isPrefix,
    required this.isNegated,
    required this.tokens,
    required this.ftsTokens,
  });

  final String text;
  final bool isQuoted;
  final bool isPrefix;
  final bool isNegated;
  final List<String> tokens;
  final List<String> ftsTokens;
}

final class _SenderFilter {
  const _SenderFilter({
    required this.matchedUserIds,
    required this.fallbackLowerOperand,
    required this.isMe,
    required this.selfUserId,
  });

  final Set<int> matchedUserIds;
  final String fallbackLowerOperand;
  final bool isMe;
  final int selfUserId;

  bool matches(Message message) {
    if (isMe) return message.senderId == selfUserId;
    if (matchedUserIds.contains(message.senderId)) return true;
    // If a former user is absent from `allUsers`, fall back to message metadata.
    if (matchedUserIds.isEmpty) {
      return message.senderEmail.toLowerCase() == fallbackLowerOperand
        || message.senderFullName.toLowerCase() == fallbackLowerOperand;
    }
    return false;
  }
}

enum _HasKind { link, image, attachment }

/// Parsed offline representation of a Zulip [KeywordSearchNarrow.keyword] query.
class ParsedMessageSearchQuery {
  ParsedMessageSearchQuery._(
    this._textTerms,
    this._positiveSenders,
    this._negatedSenders,
    this._requiredHas,
    this._forbiddenHas, {
    required this.isImpossible,
    required this.sqlSpec,
    required this.hasExplicitChannelScope,
    required this.hasExplicitTopicScope,
    required this.hasExplicitDmConversationScope,
    required this.hasExplicitSenderScope,
    required this.requiredGroupDmMembers,
    required this.excludedGroupDmMembers,
    required this.requiredDmMembers,
    required this.excludedDmMembers,
    required this.isDm,
    required this.requiredStarred,
    required this.requiredUnread,
    required this.requiredMentioned,
    required this.requiredAlerted,
    required this.requiredResolved,
    required this.requiredFollowed,
    required this.requiredMuted,
  });

  final bool isImpossible;
  final StoredMessageSearchSpec sqlSpec;

  final List<_TextQueryTerm> _textTerms;
  final bool hasExplicitChannelScope;
  final bool hasExplicitTopicScope;
  final bool hasExplicitDmConversationScope;
  final bool hasExplicitSenderScope;

  final List<_SenderFilter> _positiveSenders;
  final List<_SenderFilter> _negatedSenders;
  final Set<int> requiredGroupDmMembers;
  final Set<int> excludedGroupDmMembers;
  final Set<int> requiredDmMembers;
  final Set<int> excludedDmMembers;

  final bool? isDm;
  final bool? requiredStarred;
  final bool? requiredUnread;
  final bool? requiredMentioned;
  final bool? requiredAlerted;
  final bool? requiredResolved;
  final bool? requiredFollowed;
  final bool? requiredMuted;
  final Set<_HasKind> _requiredHas;
  final Set<_HasKind> _forbiddenHas;

  /// Parse [rawQuery] against [store] into an SQL pushdown spec and an
  /// exact in-memory post-filter.
  factory ParsedMessageSearchQuery.parse(
    String rawQuery,
    MessageSearchStore store,
  ) {
    final tokens = _lexQuery(rawQuery);

    var impossible = false;
    Set<int>? allowedChannelIds;
    final excludedChannelIds = <int>{};
    String? topicKey;
    final excludedTopicKeys = <String>{};
    bool? isDm;
    String? dmKey;
    final excludedDmKeys = <String>{};
    int? exactMessageId;
    final excludedMessageIds = <int>{};

    var hasExplicitChannelScope = false;
    var hasExplicitTopicScope = false;
    var hasExplicitDmConversationScope = false;
    var hasExplicitSenderScope = false;

    final positiveSenders = <_SenderFilter>[];
    final negatedSenders = <_SenderFilter>[];
    Set<int>? sqlAllowedSenderIds;
    final sqlExcludedSenderIds = <int>{};

    final requiredGroupDmMembers = <int>{};
    final excludedGroupDmMembers = <int>{};
    final requiredDmMembers = <int>{};
    final excludedDmMembers = <int>{};

    bool? requiredStarred;
    bool? requiredUnread;
    bool? requiredMentioned;
    bool? requiredAlerted;
    bool? requiredResolved;
    bool? requiredFollowed;
    bool? requiredMuted;

    final requiredHas = <_HasKind>{};
    final forbiddenHas = <_HasKind>{};
    final textTerms = <_TextQueryTerm>[];

    void setIsDm(bool value) {
      if (isDm != null && isDm != value) {
        impossible = true;
      } else {
        isDm = value;
      }
    }

    void intersectAllowedChannels(Set<int> channels) {
      if (allowedChannelIds == null) {
        allowedChannelIds = Set<int>.of(channels);
      } else {
        allowedChannelIds!.retainAll(channels);
      }
      if (allowedChannelIds!.isEmpty) impossible = true;
    }

    void setBoolConstraint(
      bool negated,
      bool? current,
      void Function(bool) assign,
    ) {
      final target = !negated;
      if (current != null && current != target) {
        impossible = true;
      } else {
        assign(target);
      }
    }

    void addPlainTextTerm(String text, {required bool isQuoted, required bool negated}) {
      var effectiveText = text;
      var isPrefix = false;
      if (!isQuoted && effectiveText.endsWith('*') && effectiveText.length > 1) {
        final withoutStar = effectiveText.substring(0, effectiveText.length - 1);
        final prefixTokens = tokenizeForFtsMatch(withoutStar);
        if (prefixTokens.isNotEmpty) {
          effectiveText = withoutStar;
          isPrefix = true;
        }
      }
      final parsedTokens = tokenizeForLocalSearch(effectiveText);
      final parsedFtsTokens = tokenizeForFtsMatch(effectiveText);
      if (effectiveText.isEmpty) return;
      textTerms.add(_TextQueryTerm(
        text: effectiveText,
        isQuoted: isQuoted,
        isPrefix: isPrefix,
        isNegated: negated,
        tokens: parsedTokens,
        ftsTokens: parsedFtsTokens,
      ));
    }

    for (final token in tokens) {
      final split = _splitOperator(token);
      if (split == null) {
        addPlainTextTerm(
          token.raw,
          isQuoted: token.hadQuotes,
          negated: token.negated,
        );
        continue;
      }

      final op = split.operatorName;
      final operand = split.operand;
      final negated = token.negated;

      switch (op) {
        case 'near':
          // Server positioning anchor; does not filter results.
          continue;

        case 'channel' || 'stream':
          final resolved = _resolveChannelId(operand, store);
          if (!negated) {
            hasExplicitChannelScope = true;
            setIsDm(false);
            if (resolved == null) {
              impossible = true;
            } else {
              intersectAllowedChannels({resolved});
            }
          } else if (resolved != null) {
            excludedChannelIds.add(resolved);
          }

        case 'channels' || 'streams':
          final mode = operand.toLowerCase();
          if (mode == 'public') {
            final publicIds = <int>{
              for (final s in store.streams.values)
                if (!s.inviteOnly && store.selfHasContentAccess(s)) s.streamId,
            };
            if (!negated) {
              hasExplicitChannelScope = true;
              setIsDm(false);
              intersectAllowedChannels(publicIds);
            } else {
              excludedChannelIds.addAll(publicIds);
            }
          } else if (mode == 'web-public') {
            final webPublicIds = <int>{
              for (final s in store.streams.values)
                if (s.isWebPublic && store.selfHasContentAccess(s)) s.streamId,
            };
            if (!negated) {
              hasExplicitChannelScope = true;
              setIsDm(false);
              intersectAllowedChannels(webPublicIds);
            } else {
              excludedChannelIds.addAll(webPublicIds);
            }
          } else {
            addPlainTextTerm(
              '$op:$operand',
              isQuoted: token.hadQuotes,
              negated: negated,
            );
          }

        case 'topic' || 'subject':
          final folded = serverTopicFold(operand);
          if (!negated) {
            hasExplicitTopicScope = true;
            setIsDm(false);
            if (topicKey != null && topicKey != folded) {
              impossible = true;
            } else {
              topicKey = folded;
            }
          } else {
            excludedTopicKeys.add(folded);
          }

        case 'sender' || 'from':
          final filter = _resolveSenderFilter(operand, store);
          if (!negated) {
            hasExplicitSenderScope = true;
            positiveSenders.add(filter);
            if (filter.isMe || filter.matchedUserIds.isNotEmpty) {
              final ids = filter.isMe
                ? <int>{store.selfUserId}
                : filter.matchedUserIds;
              if (sqlAllowedSenderIds == null) {
                sqlAllowedSenderIds = Set<int>.of(ids);
              } else {
                sqlAllowedSenderIds.retainAll(ids);
              }
              if (sqlAllowedSenderIds.isEmpty) impossible = true;
            }
          } else {
            negatedSenders.add(filter);
            if (filter.isMe) {
              sqlExcludedSenderIds.add(store.selfUserId);
            } else if (filter.matchedUserIds.isNotEmpty) {
              sqlExcludedSenderIds.addAll(filter.matchedUserIds);
            }
          }

        case 'dm' || 'pm-with':
          final userIds = _resolveCommaSeparatedUsers(operand, store);
          if (userIds == null || userIds.isEmpty) {
            if (!negated) impossible = true;
            continue;
          }
          final allRecipients = <int>{store.selfUserId, ...userIds};
          final key = StoredMessageCodec.dmKeyFromRecipientIds(allRecipients);
          if (!negated) {
            hasExplicitDmConversationScope = true;
            setIsDm(true);
            if (dmKey != null && dmKey != key) {
              impossible = true;
            } else {
              dmKey = key;
            }
          } else {
            excludedDmKeys.add(key);
          }

        case 'group-pm-with':
          final userIds = _resolveCommaSeparatedUsers(operand, store);
          if (userIds == null || userIds.isEmpty) {
            if (!negated) impossible = true;
            continue;
          }
          if (!negated) {
            hasExplicitDmConversationScope = true;
            setIsDm(true);
            requiredGroupDmMembers.addAll(userIds);
          } else {
            excludedGroupDmMembers.addAll(userIds);
          }

        case 'dm-including':
          final userIds = _resolveCommaSeparatedUsers(operand, store);
          if (userIds == null || userIds.isEmpty) {
            if (!negated) impossible = true;
            continue;
          }
          if (!negated) {
            hasExplicitDmConversationScope = true;
            setIsDm(true);
            requiredDmMembers.addAll(userIds);
          } else {
            excludedDmMembers.addAll(userIds);
          }

        case 'is':
          switch (operand.toLowerCase()) {
            case 'dm' || 'private':
              setIsDm(!negated);
            case 'starred':
              setBoolConstraint(negated, requiredStarred, (v) => requiredStarred = v);
            case 'unread':
              setBoolConstraint(negated, requiredUnread, (v) => requiredUnread = v);
            case 'mentioned':
              setBoolConstraint(negated, requiredMentioned, (v) => requiredMentioned = v);
            case 'alerted':
              setBoolConstraint(negated, requiredAlerted, (v) => requiredAlerted = v);
            case 'resolved':
              setBoolConstraint(negated, requiredResolved, (v) => requiredResolved = v);
            case 'followed':
              setBoolConstraint(negated, requiredFollowed, (v) => requiredFollowed = v);
            case 'muted':
              setBoolConstraint(negated, requiredMuted, (v) => requiredMuted = v);
            default:
              addPlainTextTerm(
                '$op:$operand',
                isQuoted: token.hadQuotes,
                negated: negated,
              );
          }

        case 'has':
          final kind = switch (operand.toLowerCase()) {
            'link' => _HasKind.link,
            'image' => _HasKind.image,
            'attachment' => _HasKind.attachment,
            _ => null,
          };
          if (kind == null) {
            addPlainTextTerm(
              '$op:$operand',
              isQuoted: token.hadQuotes,
              negated: negated,
            );
          } else if (!negated) {
            requiredHas.add(kind);
          } else {
            forbiddenHas.add(kind);
          }

        case 'id':
          final id = int.tryParse(operand);
          if (id == null) {
            if (!negated) impossible = true;
            continue;
          }
          if (!negated) {
            if (exactMessageId != null && exactMessageId != id) {
              impossible = true;
            } else {
              exactMessageId = id;
            }
          } else {
            excludedMessageIds.add(id);
          }

        default:
          // Unknown `foo:bar` is treated as literal search text (like Zulip web).
          addPlainTextTerm(
            '$op:$operand',
            isQuoted: token.hadQuotes,
            negated: negated,
          );
      }
    }

    if (allowedChannelIds != null) {
      allowedChannelIds!.removeAll(excludedChannelIds);
      if (allowedChannelIds!.isEmpty) impossible = true;
    }
    if (topicKey != null && excludedTopicKeys.contains(topicKey)) {
      impossible = true;
    }
    if (dmKey != null && excludedDmKeys.contains(dmKey)) {
      impossible = true;
    }
    if (exactMessageId != null && excludedMessageIds.contains(exactMessageId)) {
      impossible = true;
    }
    if (requiredHas.any(forbiddenHas.contains)) {
      impossible = true;
    }
    if ((requiredResolved == true || requiredFollowed == true) && isDm == true) {
      impossible = true;
    }

    final positiveFtsClauses = <String>[];
    final negatedFtsClauses = <String>[];
    for (final term in textTerms) {
      if (term.ftsTokens.isEmpty) continue;
      if (!term.isNegated) {
        if (term.isQuoted && term.ftsTokens.length > 1) {
          positiveFtsClauses.add('"${term.ftsTokens.join(' ')}"');
        } else if (term.isPrefix) {
          for (var i = 0; i < term.ftsTokens.length - 1; i++) {
            positiveFtsClauses.add('"${term.ftsTokens[i]}"');
          }
          positiveFtsClauses.add('"${term.ftsTokens.last}"*');
        } else {
          for (final t in term.ftsTokens) {
            positiveFtsClauses.add('"$t"');
          }
        }
      } else if (!term.isPrefix
          && term.ftsTokens.length == 1
          && _asciiTokenRegExp.hasMatch(term.ftsTokens.single)) {
        // Single-token ASCII non-prefix negation matches Dart folding in FTS5.
        // Multi-token, prefix, or non-ASCII negations are evaluated in Dart.
        negatedFtsClauses.add('"${term.ftsTokens.single}"');
      }
    }

    var requiredFlagsMask = 0;
    var forbiddenFlagsMask = 0;
    var anyFlagsMask = 0;

    if (requiredMentioned == true) {
      anyFlagsMask = StoredMessageFlags.mentioned
        | StoredMessageFlags.streamWildcardMentioned
        | StoredMessageFlags.topicWildcardMentioned;
    } else if (requiredMentioned == false) {
      forbiddenFlagsMask |= StoredMessageFlags.mentioned
        | StoredMessageFlags.streamWildcardMentioned
        | StoredMessageFlags.topicWildcardMentioned;
    }

    if (requiredAlerted == true) {
      requiredFlagsMask |= StoredMessageFlags.hasAlertWord;
    } else if (requiredAlerted == false) {
      forbiddenFlagsMask |= StoredMessageFlags.hasAlertWord;
    }

    if (requiredFlagsMask != 0
        && (requiredFlagsMask & forbiddenFlagsMask) != 0) {
      impossible = true;
    }

    Set<int>? allowedMessageIds;
    if (requiredStarred == true && !store.isStarredMessagesAtCap) {
      allowedMessageIds = Set<int>.of(store.starredMessages);
      if (exactMessageId != null) {
        allowedMessageIds.retainAll({exactMessageId});
      }
      allowedMessageIds.removeAll(excludedMessageIds);
      if (allowedMessageIds.isEmpty) {
        impossible = true;
      }
    }

    final sqlSpec = StoredMessageSearchSpec(
      positiveFtsMatch:
        positiveFtsClauses.isEmpty ? null : positiveFtsClauses.join(' AND '),
      negatedFtsMatch:
        negatedFtsClauses.isEmpty ? null : negatedFtsClauses.join(' OR '),
      allowedChannelIds: allowedChannelIds,
      excludedChannelIds: excludedChannelIds,
      topicKey: topicKey,
      excludedTopicKeys: excludedTopicKeys,
      isDm: isDm,
      dmKey: dmKey,
      excludedDmKeys: excludedDmKeys,
      allowedSenderIds: sqlAllowedSenderIds,
      excludedSenderIds: sqlExcludedSenderIds,
      requiredFlagsMask: requiredFlagsMask,
      forbiddenFlagsMask: forbiddenFlagsMask,
      anyFlagsMask: anyFlagsMask,
      exactMessageId: exactMessageId,
      allowedMessageIds: allowedMessageIds,
      excludedMessageIds: excludedMessageIds,
    );

    return ParsedMessageSearchQuery._(
      textTerms,
      positiveSenders,
      negatedSenders,
      requiredHas,
      forbiddenHas,
      isImpossible: impossible,
      sqlSpec: sqlSpec,
      hasExplicitChannelScope: hasExplicitChannelScope,
      hasExplicitTopicScope: hasExplicitTopicScope,
      hasExplicitDmConversationScope: hasExplicitDmConversationScope,
      hasExplicitSenderScope: hasExplicitSenderScope,
      requiredGroupDmMembers: requiredGroupDmMembers,
      excludedGroupDmMembers: excludedGroupDmMembers,
      requiredDmMembers: requiredDmMembers,
      excludedDmMembers: excludedDmMembers,
      isDm: isDm,
      requiredStarred: requiredStarred,
      requiredUnread: requiredUnread,
      requiredMentioned: requiredMentioned,
      requiredAlerted: requiredAlerted,
      requiredResolved: requiredResolved,
      requiredFollowed: requiredFollowed,
      requiredMuted: requiredMuted,
    );
  }

  /// Evaluate the full query (operators, muting, access control, and text)
  /// against an already access-checked live/decoded [Message].
  bool matchesMessage(Message message, MessageSearchStore store) {
    if (isImpossible) return false;

    if (sqlSpec.exactMessageId != null && message.id != sqlSpec.exactMessageId) {
      return false;
    }
    if (sqlSpec.excludedMessageIds.contains(message.id)) {
      return false;
    }

    // Channel/DM constraints & muting defaults.
    switch (message) {
      case StreamMessage():
        if (isDm == true) return false;
        final channel = store.streams[message.streamId];
        if (channel == null || !store.selfHasContentAccess(channel)) {
          return false;
        }
        final allowed = sqlSpec.allowedChannelIds;
        if (allowed != null && !allowed.contains(message.streamId)) {
          return false;
        }
        if (sqlSpec.excludedChannelIds.contains(message.streamId)) {
          return false;
        }
        final foldedTopic = serverTopicFold(message.topic.apiName);
        if (sqlSpec.topicKey != null && foldedTopic != sqlSpec.topicKey) {
          return false;
        }
        if (sqlSpec.excludedTopicKeys.contains(foldedTopic)) {
          return false;
        }

        final sub = store.subscriptions[message.streamId];
        final isVisibleInCh = store.isTopicVisibleInChannel(message.streamId, message.topic);
        final policy = store.topicVisibilityPolicy(message.streamId, message.topic);
        final isMuted = !isVisibleInCh
          || ((sub?.isMuted ?? false) && policy == UserTopicVisibilityPolicy.none);
        if (requiredMuted == true) {
          if (!hasExplicitChannelScope && sub == null) return false;
          if (!isMuted) return false;
        } else if (requiredMuted == false) {
          if (!hasExplicitChannelScope && sub == null) return false;
          if (isMuted) return false;
        } else {
          if (hasExplicitChannelScope && hasExplicitTopicScope) {
            // Explicit `channel:` + `topic:` bypasses channel and topic muting.
          } else if (hasExplicitChannelScope) {
            if (!isVisibleInCh) return false;
          } else if (hasExplicitTopicScope) {
            // Explicit `topic:` bypasses topic muting while respecting channel subscription/muting.
            if (sub == null || (sub.isMuted && policy == UserTopicVisibilityPolicy.none)) {
              return false;
            }
          } else {
            if (!store.isTopicVisible(message.streamId, message.topic)) return false;
          }
        }

        if (requiredResolved != null && message.topic.isResolved != requiredResolved) {
          return false;
        }
        if (requiredFollowed != null) {
          final isFollowed =
            store.topicVisibilityPolicy(message.streamId, message.topic)
              == UserTopicVisibilityPolicy.followed;
          if (isFollowed != requiredFollowed) return false;
        }

      case DmMessage():
        if (isDm == false) return false;
        if (requiredResolved == true || requiredFollowed == true) return false;
        final key = StoredMessageCodec.dmKey(message);
        if (sqlSpec.dmKey != null && key != sqlSpec.dmKey) return false;
        if (sqlSpec.excludedDmKeys.contains(key)) return false;

        final recipients = message.allRecipientIds;
        for (final id in requiredDmMembers) {
          if (!recipients.contains(id)) return false;
        }
        if (excludedDmMembers.any(recipients.contains)) return false;

        if (requiredGroupDmMembers.isNotEmpty) {
          if (recipients.length < 3) return false;
          for (final id in requiredGroupDmMembers) {
            if (!recipients.contains(id)) return false;
          }
        }
        if (excludedGroupDmMembers.isNotEmpty
            && recipients.length >= 3
            && excludedGroupDmMembers.any(recipients.contains)) {
          return false;
        }

        final dmMuted = store.shouldMuteDmConversation(
          DmNarrow.ofMessage(message, selfUserId: store.selfUserId),
        );
        if (requiredMuted == true) {
          if (!dmMuted) return false;
        } else if (requiredMuted == false) {
          if (dmMuted) return false;
        } else if (!hasExplicitDmConversationScope) {
          if (dmMuted) return false;
        }
    }

    // Sender constraints.
    for (final s in _positiveSenders) {
      if (!s.matches(message)) return false;
    }
    for (final s in _negatedSenders) {
      if (s.matches(message)) return false;
    }

    // Live flags constraints.
    if (requiredStarred != null
        && message.flags.contains(MessageFlag.starred) != requiredStarred) {
      return false;
    }
    if (requiredUnread != null
        && (!message.flags.contains(MessageFlag.read)) != requiredUnread) {
      return false;
    }
    if (requiredMentioned != null
        && message.flags.any((f) => f.isMentionFlag) != requiredMentioned) {
      return false;
    }
    if (requiredAlerted != null
        && message.flags.contains(MessageFlag.hasAlertWord) != requiredAlerted) {
      return false;
    }

    // Content attachment / link / image constraints.
    for (final kind in _requiredHas) {
      if (!_matchesHasKind(message.content, kind)) return false;
    }
    for (final kind in _forbiddenHas) {
      if (_matchesHasKind(message.content, kind)) return false;
    }

    if (_textTerms.isEmpty) return true;

    final topicRaw = message is StreamMessage ? message.topic.apiName : '';
    final bodyRaw = extractSearchBodyTextFromMessage(message);
    final topicTokens = tokenizeForLocalSearch(topicRaw);
    final bodyTokens = tokenizeForLocalSearch(bodyRaw);
    final allTokens = <String>{...topicTokens, ...bodyTokens};
    String? foldedCombined;

    bool termMatches(_TextQueryTerm term) {
      if (term.tokens.isEmpty) {
        foldedCombined ??= foldForLocalSearch(
          topicRaw.isEmpty ? bodyRaw : '$topicRaw $bodyRaw',
        );
        final needle = foldForLocalSearch(term.text);
        return needle.isNotEmpty && foldedCombined!.contains(needle);
      }
      if (term.isQuoted && term.tokens.length > 1) {
        return _containsTokenSequence(topicTokens, term.tokens)
          || _containsTokenSequence(bodyTokens, term.tokens);
      }
      if (term.isPrefix) {
        for (var i = 0; i < term.tokens.length - 1; i++) {
          if (!allTokens.contains(term.tokens[i])) return false;
        }
        final prefix = term.tokens.last;
        return allTokens.any((t) => t.startsWith(prefix));
      }
      for (final t in term.tokens) {
        if (!allTokens.contains(t)) return false;
      }
      return true;
    }

    for (final term in _textTerms) {
      final matched = termMatches(term);
      if (term.isNegated ? matched : !matched) return false;
    }
    return true;
  }

  static bool _matchesHasKind(String htmlContent, _HasKind kind) {
    return switch (kind) {
      _HasKind.link => _hasLinkRegExp.hasMatch(htmlContent),
      _HasKind.image => _hasImageRegExp.hasMatch(htmlContent),
      _HasKind.attachment => _hasAttachmentRegExp.hasMatch(htmlContent),
    };
  }

  static bool _containsTokenSequence(List<String> haystack, List<String> needle) {
    if (needle.isEmpty) return true;
    if (haystack.length < needle.length) return false;
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  static List<_LexedToken> _lexQuery(String raw) {
    final result = <_LexedToken>[];
    var i = 0;
    final len = raw.length;

    bool isSpace(int codeUnit) =>
      codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A || codeUnit == 0x0D;

    while (i < len) {
      while (i < len && isSpace(raw.codeUnitAt(i))) {
        i++;
      }
      if (i >= len) break;

      var negated = false;
      if (raw[i] == '-') {
        negated = true;
        i++;
        if (i >= len || isSpace(raw.codeUnitAt(i))) {
          // Bare '-' token.
          result.add(const _LexedToken(
            raw: '-',
            negated: false,
            hadQuotes: false,
            unquotedColonIndex: null,
          ));
          continue;
        }
      }

      final buf = StringBuffer();
      var inQuotes = false;
      var hadQuotes = false;
      int? unquotedColonIndex;
      while (i < len) {
        final ch = raw[i];
        if (!inQuotes && isSpace(raw.codeUnitAt(i))) break;
        if (ch == '"') {
          inQuotes = !inQuotes;
          hadQuotes = true;
          i++;
          continue;
        }
        if (ch == ':' && !inQuotes && !hadQuotes && unquotedColonIndex == null) {
          unquotedColonIndex = buf.length;
        }
        buf.write(ch);
        i++;
      }
      result.add(_LexedToken(
        raw: buf.toString(),
        negated: negated,
        hadQuotes: hadQuotes,
        unquotedColonIndex: unquotedColonIndex,
      ));
    }
    return result;
  }

  static ({String operatorName, String operand})? _splitOperator(_LexedToken token) {
    final colon = token.unquotedColonIndex;
    if (colon == null || colon <= 0) return null;
    final text = token.raw;
    final prefix = text.substring(0, colon);
    if (!_operatorPrefixRegExp.hasMatch(prefix)) return null;
    return (
      operatorName: prefix.toLowerCase(),
      operand: text.substring(colon + 1),
    );
  }

  static int? _resolveChannelId(String operand, MessageSearchStore store) {
    final lower = operand.toLowerCase();
    for (final s in store.streams.values) {
      if (s.name.toLowerCase() == lower) {
        return store.selfHasContentAccess(s) ? s.streamId : null;
      }
    }
    final byId = int.tryParse(operand);
    if (byId != null) {
      final s = store.streams[byId];
      if (s != null && store.selfHasContentAccess(s)) return s.streamId;
    }
    return null;
  }

  static _SenderFilter _resolveSenderFilter(
    String operand,
    MessageSearchStore store,
  ) {
    final lower = operand.toLowerCase();
    if (lower == 'me') {
      return _SenderFilter(
        matchedUserIds: {store.selfUserId},
        fallbackLowerOperand: lower,
        isMe: true,
        selfUserId: store.selfUserId,
      );
    }
    final matched = <int>{};
    for (final user in store.allUsers) {
      if (user.email.toLowerCase() == lower
          || user.deliveryEmail?.toLowerCase() == lower
          || user.fullName.toLowerCase() == lower) {
        matched.add(user.userId);
      }
    }
    final asId = int.tryParse(operand);
    if (asId != null && store.getUser(asId) != null) {
      matched.add(asId);
    }
    return _SenderFilter(
      matchedUserIds: matched,
      fallbackLowerOperand: lower,
      isMe: false,
      selfUserId: store.selfUserId,
    );
  }

  static Set<int>? _resolveCommaSeparatedUsers(
    String operand,
    MessageSearchStore store,
  ) {
    if (operand.isEmpty) return null;
    final parts = operand.split(',');
    final ids = <int>{};
    for (final rawPart in parts) {
      final part = rawPart.trim();
      if (part.isEmpty) return null;
      final lower = part.toLowerCase();
      if (lower == 'me') {
        ids.add(store.selfUserId);
        continue;
      }
      int? found;
      for (final user in store.allUsers) {
        if (user.email.toLowerCase() == lower
            || user.deliveryEmail?.toLowerCase() == lower
            || user.fullName.toLowerCase() == lower) {
          found = user.userId;
          break;
        }
      }
      if (found == null) {
        final asId = int.tryParse(part);
        if (asId != null && store.getUser(asId) != null) {
          found = asId;
        }
      }
      if (found == null) return null;
      ids.add(found);
    }
    return ids;
  }
}
