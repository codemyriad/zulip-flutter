// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: constant_identifier_names, unnecessary_cast

part of 'message_database.dart';

// ignore_for_file: type=lint
class $MessageDbAccountsTable extends MessageDbAccounts
    with TableInfo<$MessageDbAccountsTable, MessageDbAccount> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageDbAccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _realmUrlMeta = const VerificationMeta(
    'realmUrl',
  );
  @override
  late final GeneratedColumn<String> realmUrl = GeneratedColumn<String>(
    'realm_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _formatVersionMeta = const VerificationMeta(
    'formatVersion',
  );
  @override
  late final GeneratedColumn<int> formatVersion = GeneratedColumn<int>(
    'format_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _queueIdMeta = const VerificationMeta(
    'queueId',
  );
  @override
  late final GeneratedColumn<String> queueId = GeneratedColumn<String>(
    'queue_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _appliedThroughEventIdMeta =
      const VerificationMeta('appliedThroughEventId');
  @override
  late final GeneratedColumn<int> appliedThroughEventId = GeneratedColumn<int>(
    'applied_through_event_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _eventHighWaterMeta = const VerificationMeta(
    'eventHighWater',
  );
  @override
  late final GeneratedColumn<int> eventHighWater = GeneratedColumn<int>(
    'event_high_water',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastLiveAtMeta = const VerificationMeta(
    'lastLiveAt',
  );
  @override
  late final GeneratedColumn<int> lastLiveAt = GeneratedColumn<int>(
    'last_live_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _evictedBelowMessageIdMeta =
      const VerificationMeta('evictedBelowMessageId');
  @override
  late final GeneratedColumn<int> evictedBelowMessageId = GeneratedColumn<int>(
    'evicted_below_message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalBodyBytesMeta = const VerificationMeta(
    'totalBodyBytes',
  );
  @override
  late final GeneratedColumn<int> totalBodyBytes = GeneratedColumn<int>(
    'total_body_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    realmUrl,
    userId,
    formatVersion,
    epoch,
    queueId,
    appliedThroughEventId,
    eventHighWater,
    lastLiveAt,
    evictedBelowMessageId,
    totalBodyBytes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_db_accounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageDbAccount> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('realm_url')) {
      context.handle(
        _realmUrlMeta,
        realmUrl.isAcceptableOrUnknown(data['realm_url']!, _realmUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_realmUrlMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('format_version')) {
      context.handle(
        _formatVersionMeta,
        formatVersion.isAcceptableOrUnknown(
          data['format_version']!,
          _formatVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_formatVersionMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('queue_id')) {
      context.handle(
        _queueIdMeta,
        queueId.isAcceptableOrUnknown(data['queue_id']!, _queueIdMeta),
      );
    }
    if (data.containsKey('applied_through_event_id')) {
      context.handle(
        _appliedThroughEventIdMeta,
        appliedThroughEventId.isAcceptableOrUnknown(
          data['applied_through_event_id']!,
          _appliedThroughEventIdMeta,
        ),
      );
    }
    if (data.containsKey('event_high_water')) {
      context.handle(
        _eventHighWaterMeta,
        eventHighWater.isAcceptableOrUnknown(
          data['event_high_water']!,
          _eventHighWaterMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_eventHighWaterMeta);
    }
    if (data.containsKey('last_live_at')) {
      context.handle(
        _lastLiveAtMeta,
        lastLiveAt.isAcceptableOrUnknown(
          data['last_live_at']!,
          _lastLiveAtMeta,
        ),
      );
    }
    if (data.containsKey('evicted_below_message_id')) {
      context.handle(
        _evictedBelowMessageIdMeta,
        evictedBelowMessageId.isAcceptableOrUnknown(
          data['evicted_below_message_id']!,
          _evictedBelowMessageIdMeta,
        ),
      );
    }
    if (data.containsKey('total_body_bytes')) {
      context.handle(
        _totalBodyBytesMeta,
        totalBodyBytes.isAcceptableOrUnknown(
          data['total_body_bytes']!,
          _totalBodyBytesMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  MessageDbAccount map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageDbAccount(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      realmUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}realm_url'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      formatVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}format_version'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      queueId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}queue_id'],
      ),
      appliedThroughEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}applied_through_event_id'],
      ),
      eventHighWater: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}event_high_water'],
      )!,
      lastLiveAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_live_at'],
      ),
      evictedBelowMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}evicted_below_message_id'],
      )!,
      totalBodyBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_body_bytes'],
      )!,
    );
  }

  @override
  $MessageDbAccountsTable createAlias(String alias) {
    return $MessageDbAccountsTable(attachedDatabase, alias);
  }
}

class MessageDbAccount extends DataClass
    implements Insertable<MessageDbAccount> {
  final int accountId;
  final String realmUrl;
  final int userId;
  final int formatVersion;
  final int epoch;
  final String? queueId;

  /// Every event with id <= this has had its effects committed here.
  ///
  /// Null after the writer was poisoned: the next start wipes the account's
  /// rows and coverage.
  final int? appliedThroughEventId;

  /// Max message id among register `max_message_id` and `message` events
  /// applied in the current epoch. Open intervals close here on epoch end.
  final int eventHighWater;

  /// Unix seconds of the last successful poll applied in the current epoch.
  final int? lastLiveAt;

  /// Rows with id < this were evicted or purged by retention.
  final int evictedBelowMessageId;

  /// Running sum of stored message body bytes, kept by every write job.
  final int totalBodyBytes;
  const MessageDbAccount({
    required this.accountId,
    required this.realmUrl,
    required this.userId,
    required this.formatVersion,
    required this.epoch,
    this.queueId,
    this.appliedThroughEventId,
    required this.eventHighWater,
    this.lastLiveAt,
    required this.evictedBelowMessageId,
    required this.totalBodyBytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['realm_url'] = Variable<String>(realmUrl);
    map['user_id'] = Variable<int>(userId);
    map['format_version'] = Variable<int>(formatVersion);
    map['epoch'] = Variable<int>(epoch);
    if (!nullToAbsent || queueId != null) {
      map['queue_id'] = Variable<String>(queueId);
    }
    if (!nullToAbsent || appliedThroughEventId != null) {
      map['applied_through_event_id'] = Variable<int>(appliedThroughEventId);
    }
    map['event_high_water'] = Variable<int>(eventHighWater);
    if (!nullToAbsent || lastLiveAt != null) {
      map['last_live_at'] = Variable<int>(lastLiveAt);
    }
    map['evicted_below_message_id'] = Variable<int>(evictedBelowMessageId);
    map['total_body_bytes'] = Variable<int>(totalBodyBytes);
    return map;
  }

  MessageDbAccountsCompanion toCompanion(bool nullToAbsent) {
    return MessageDbAccountsCompanion(
      accountId: Value(accountId),
      realmUrl: Value(realmUrl),
      userId: Value(userId),
      formatVersion: Value(formatVersion),
      epoch: Value(epoch),
      queueId: queueId == null && nullToAbsent
          ? const Value.absent()
          : Value(queueId),
      appliedThroughEventId: appliedThroughEventId == null && nullToAbsent
          ? const Value.absent()
          : Value(appliedThroughEventId),
      eventHighWater: Value(eventHighWater),
      lastLiveAt: lastLiveAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastLiveAt),
      evictedBelowMessageId: Value(evictedBelowMessageId),
      totalBodyBytes: Value(totalBodyBytes),
    );
  }

  factory MessageDbAccount.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageDbAccount(
      accountId: serializer.fromJson<int>(json['accountId']),
      realmUrl: serializer.fromJson<String>(json['realmUrl']),
      userId: serializer.fromJson<int>(json['userId']),
      formatVersion: serializer.fromJson<int>(json['formatVersion']),
      epoch: serializer.fromJson<int>(json['epoch']),
      queueId: serializer.fromJson<String?>(json['queueId']),
      appliedThroughEventId: serializer.fromJson<int?>(
        json['appliedThroughEventId'],
      ),
      eventHighWater: serializer.fromJson<int>(json['eventHighWater']),
      lastLiveAt: serializer.fromJson<int?>(json['lastLiveAt']),
      evictedBelowMessageId: serializer.fromJson<int>(
        json['evictedBelowMessageId'],
      ),
      totalBodyBytes: serializer.fromJson<int>(json['totalBodyBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'realmUrl': serializer.toJson<String>(realmUrl),
      'userId': serializer.toJson<int>(userId),
      'formatVersion': serializer.toJson<int>(formatVersion),
      'epoch': serializer.toJson<int>(epoch),
      'queueId': serializer.toJson<String?>(queueId),
      'appliedThroughEventId': serializer.toJson<int?>(appliedThroughEventId),
      'eventHighWater': serializer.toJson<int>(eventHighWater),
      'lastLiveAt': serializer.toJson<int?>(lastLiveAt),
      'evictedBelowMessageId': serializer.toJson<int>(evictedBelowMessageId),
      'totalBodyBytes': serializer.toJson<int>(totalBodyBytes),
    };
  }

  MessageDbAccount copyWith({
    int? accountId,
    String? realmUrl,
    int? userId,
    int? formatVersion,
    int? epoch,
    Value<String?> queueId = const Value.absent(),
    Value<int?> appliedThroughEventId = const Value.absent(),
    int? eventHighWater,
    Value<int?> lastLiveAt = const Value.absent(),
    int? evictedBelowMessageId,
    int? totalBodyBytes,
  }) => MessageDbAccount(
    accountId: accountId ?? this.accountId,
    realmUrl: realmUrl ?? this.realmUrl,
    userId: userId ?? this.userId,
    formatVersion: formatVersion ?? this.formatVersion,
    epoch: epoch ?? this.epoch,
    queueId: queueId.present ? queueId.value : this.queueId,
    appliedThroughEventId: appliedThroughEventId.present
        ? appliedThroughEventId.value
        : this.appliedThroughEventId,
    eventHighWater: eventHighWater ?? this.eventHighWater,
    lastLiveAt: lastLiveAt.present ? lastLiveAt.value : this.lastLiveAt,
    evictedBelowMessageId: evictedBelowMessageId ?? this.evictedBelowMessageId,
    totalBodyBytes: totalBodyBytes ?? this.totalBodyBytes,
  );
  MessageDbAccount copyWithCompanion(MessageDbAccountsCompanion data) {
    return MessageDbAccount(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      realmUrl: data.realmUrl.present ? data.realmUrl.value : this.realmUrl,
      userId: data.userId.present ? data.userId.value : this.userId,
      formatVersion: data.formatVersion.present
          ? data.formatVersion.value
          : this.formatVersion,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      queueId: data.queueId.present ? data.queueId.value : this.queueId,
      appliedThroughEventId: data.appliedThroughEventId.present
          ? data.appliedThroughEventId.value
          : this.appliedThroughEventId,
      eventHighWater: data.eventHighWater.present
          ? data.eventHighWater.value
          : this.eventHighWater,
      lastLiveAt: data.lastLiveAt.present
          ? data.lastLiveAt.value
          : this.lastLiveAt,
      evictedBelowMessageId: data.evictedBelowMessageId.present
          ? data.evictedBelowMessageId.value
          : this.evictedBelowMessageId,
      totalBodyBytes: data.totalBodyBytes.present
          ? data.totalBodyBytes.value
          : this.totalBodyBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageDbAccount(')
          ..write('accountId: $accountId, ')
          ..write('realmUrl: $realmUrl, ')
          ..write('userId: $userId, ')
          ..write('formatVersion: $formatVersion, ')
          ..write('epoch: $epoch, ')
          ..write('queueId: $queueId, ')
          ..write('appliedThroughEventId: $appliedThroughEventId, ')
          ..write('eventHighWater: $eventHighWater, ')
          ..write('lastLiveAt: $lastLiveAt, ')
          ..write('evictedBelowMessageId: $evictedBelowMessageId, ')
          ..write('totalBodyBytes: $totalBodyBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    realmUrl,
    userId,
    formatVersion,
    epoch,
    queueId,
    appliedThroughEventId,
    eventHighWater,
    lastLiveAt,
    evictedBelowMessageId,
    totalBodyBytes,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageDbAccount &&
          other.accountId == this.accountId &&
          other.realmUrl == this.realmUrl &&
          other.userId == this.userId &&
          other.formatVersion == this.formatVersion &&
          other.epoch == this.epoch &&
          other.queueId == this.queueId &&
          other.appliedThroughEventId == this.appliedThroughEventId &&
          other.eventHighWater == this.eventHighWater &&
          other.lastLiveAt == this.lastLiveAt &&
          other.evictedBelowMessageId == this.evictedBelowMessageId &&
          other.totalBodyBytes == this.totalBodyBytes);
}

class MessageDbAccountsCompanion extends UpdateCompanion<MessageDbAccount> {
  final Value<int> accountId;
  final Value<String> realmUrl;
  final Value<int> userId;
  final Value<int> formatVersion;
  final Value<int> epoch;
  final Value<String?> queueId;
  final Value<int?> appliedThroughEventId;
  final Value<int> eventHighWater;
  final Value<int?> lastLiveAt;
  final Value<int> evictedBelowMessageId;
  final Value<int> totalBodyBytes;
  const MessageDbAccountsCompanion({
    this.accountId = const Value.absent(),
    this.realmUrl = const Value.absent(),
    this.userId = const Value.absent(),
    this.formatVersion = const Value.absent(),
    this.epoch = const Value.absent(),
    this.queueId = const Value.absent(),
    this.appliedThroughEventId = const Value.absent(),
    this.eventHighWater = const Value.absent(),
    this.lastLiveAt = const Value.absent(),
    this.evictedBelowMessageId = const Value.absent(),
    this.totalBodyBytes = const Value.absent(),
  });
  MessageDbAccountsCompanion.insert({
    this.accountId = const Value.absent(),
    required String realmUrl,
    required int userId,
    required int formatVersion,
    required int epoch,
    this.queueId = const Value.absent(),
    this.appliedThroughEventId = const Value.absent(),
    required int eventHighWater,
    this.lastLiveAt = const Value.absent(),
    this.evictedBelowMessageId = const Value.absent(),
    this.totalBodyBytes = const Value.absent(),
  }) : realmUrl = Value(realmUrl),
       userId = Value(userId),
       formatVersion = Value(formatVersion),
       epoch = Value(epoch),
       eventHighWater = Value(eventHighWater);
  static Insertable<MessageDbAccount> custom({
    Expression<int>? accountId,
    Expression<String>? realmUrl,
    Expression<int>? userId,
    Expression<int>? formatVersion,
    Expression<int>? epoch,
    Expression<String>? queueId,
    Expression<int>? appliedThroughEventId,
    Expression<int>? eventHighWater,
    Expression<int>? lastLiveAt,
    Expression<int>? evictedBelowMessageId,
    Expression<int>? totalBodyBytes,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (realmUrl != null) 'realm_url': realmUrl,
      if (userId != null) 'user_id': userId,
      if (formatVersion != null) 'format_version': formatVersion,
      if (epoch != null) 'epoch': epoch,
      if (queueId != null) 'queue_id': queueId,
      if (appliedThroughEventId != null)
        'applied_through_event_id': appliedThroughEventId,
      if (eventHighWater != null) 'event_high_water': eventHighWater,
      if (lastLiveAt != null) 'last_live_at': lastLiveAt,
      if (evictedBelowMessageId != null)
        'evicted_below_message_id': evictedBelowMessageId,
      if (totalBodyBytes != null) 'total_body_bytes': totalBodyBytes,
    });
  }

  MessageDbAccountsCompanion copyWith({
    Value<int>? accountId,
    Value<String>? realmUrl,
    Value<int>? userId,
    Value<int>? formatVersion,
    Value<int>? epoch,
    Value<String?>? queueId,
    Value<int?>? appliedThroughEventId,
    Value<int>? eventHighWater,
    Value<int?>? lastLiveAt,
    Value<int>? evictedBelowMessageId,
    Value<int>? totalBodyBytes,
  }) {
    return MessageDbAccountsCompanion(
      accountId: accountId ?? this.accountId,
      realmUrl: realmUrl ?? this.realmUrl,
      userId: userId ?? this.userId,
      formatVersion: formatVersion ?? this.formatVersion,
      epoch: epoch ?? this.epoch,
      queueId: queueId ?? this.queueId,
      appliedThroughEventId:
          appliedThroughEventId ?? this.appliedThroughEventId,
      eventHighWater: eventHighWater ?? this.eventHighWater,
      lastLiveAt: lastLiveAt ?? this.lastLiveAt,
      evictedBelowMessageId:
          evictedBelowMessageId ?? this.evictedBelowMessageId,
      totalBodyBytes: totalBodyBytes ?? this.totalBodyBytes,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (realmUrl.present) {
      map['realm_url'] = Variable<String>(realmUrl.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (formatVersion.present) {
      map['format_version'] = Variable<int>(formatVersion.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (queueId.present) {
      map['queue_id'] = Variable<String>(queueId.value);
    }
    if (appliedThroughEventId.present) {
      map['applied_through_event_id'] = Variable<int>(
        appliedThroughEventId.value,
      );
    }
    if (eventHighWater.present) {
      map['event_high_water'] = Variable<int>(eventHighWater.value);
    }
    if (lastLiveAt.present) {
      map['last_live_at'] = Variable<int>(lastLiveAt.value);
    }
    if (evictedBelowMessageId.present) {
      map['evicted_below_message_id'] = Variable<int>(
        evictedBelowMessageId.value,
      );
    }
    if (totalBodyBytes.present) {
      map['total_body_bytes'] = Variable<int>(totalBodyBytes.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageDbAccountsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('realmUrl: $realmUrl, ')
          ..write('userId: $userId, ')
          ..write('formatVersion: $formatVersion, ')
          ..write('epoch: $epoch, ')
          ..write('queueId: $queueId, ')
          ..write('appliedThroughEventId: $appliedThroughEventId, ')
          ..write('eventHighWater: $eventHighWater, ')
          ..write('lastLiveAt: $lastLiveAt, ')
          ..write('evictedBelowMessageId: $evictedBelowMessageId, ')
          ..write('totalBodyBytes: $totalBodyBytes')
          ..write(')'))
        .toString();
  }
}

class $StoredMessagesTable extends StoredMessages
    with TableInfo<$StoredMessagesTable, StoredMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StoredMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES message_db_accounts (account_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _channelIdMeta = const VerificationMeta(
    'channelId',
  );
  @override
  late final GeneratedColumn<int> channelId = GeneratedColumn<int>(
    'channel_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _topicMeta = const VerificationMeta('topic');
  @override
  late final GeneratedColumn<String> topic = GeneratedColumn<String>(
    'topic',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _topicKeyMeta = const VerificationMeta(
    'topicKey',
  );
  @override
  late final GeneratedColumn<String> topicKey = GeneratedColumn<String>(
    'topic_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dmKeyMeta = const VerificationMeta('dmKey');
  @override
  late final GeneratedColumn<String> dmKey = GeneratedColumn<String>(
    'dm_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _senderIdMeta = const VerificationMeta(
    'senderId',
  );
  @override
  late final GeneratedColumn<int> senderId = GeneratedColumn<int>(
    'sender_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _flagsMeta = const VerificationMeta('flags');
  @override
  late final GeneratedColumn<int> flags = GeneratedColumn<int>(
    'flags',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _unknownFlagsMeta = const VerificationMeta(
    'unknownFlags',
  );
  @override
  late final GeneratedColumn<String> unknownFlags = GeneratedColumn<String>(
    'unknown_flags',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isMeMessageMeta = const VerificationMeta(
    'isMeMessage',
  );
  @override
  late final GeneratedColumn<bool> isMeMessage = GeneratedColumn<bool>(
    'is_me_message',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_me_message" IN (0, 1))',
    ),
  );
  static const VerificationMeta _editStateMeta = const VerificationMeta(
    'editState',
  );
  @override
  late final GeneratedColumn<int> editState = GeneratedColumn<int>(
    'edit_state',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastEditTimestampMeta = const VerificationMeta(
    'lastEditTimestamp',
  );
  @override
  late final GeneratedColumn<int> lastEditTimestamp = GeneratedColumn<int>(
    'last_edit_timestamp',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _displayRecipientClearedMeta =
      const VerificationMeta('displayRecipientCleared');
  @override
  late final GeneratedColumn<bool> displayRecipientCleared =
      GeneratedColumn<bool>(
        'display_recipient_cleared',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: true,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("display_recipient_cleared" IN (0, 1))',
        ),
      );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _trackedMeta = const VerificationMeta(
    'tracked',
  );
  @override
  late final GeneratedColumn<bool> tracked = GeneratedColumn<bool>(
    'tracked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("tracked" IN (0, 1))',
    ),
  );
  static const VerificationMeta _bodyBytesMeta = const VerificationMeta(
    'bodyBytes',
  );
  @override
  late final GeneratedColumn<int> bodyBytes = GeneratedColumn<int>(
    'body_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    id,
    channelId,
    topic,
    topicKey,
    dmKey,
    senderId,
    timestamp,
    flags,
    unknownFlags,
    isMeMessage,
    editState,
    lastEditTimestamp,
    displayRecipientCleared,
    epoch,
    tracked,
    bodyBytes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stored_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('channel_id')) {
      context.handle(
        _channelIdMeta,
        channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta),
      );
    }
    if (data.containsKey('topic')) {
      context.handle(
        _topicMeta,
        topic.isAcceptableOrUnknown(data['topic']!, _topicMeta),
      );
    }
    if (data.containsKey('topic_key')) {
      context.handle(
        _topicKeyMeta,
        topicKey.isAcceptableOrUnknown(data['topic_key']!, _topicKeyMeta),
      );
    }
    if (data.containsKey('dm_key')) {
      context.handle(
        _dmKeyMeta,
        dmKey.isAcceptableOrUnknown(data['dm_key']!, _dmKeyMeta),
      );
    }
    if (data.containsKey('sender_id')) {
      context.handle(
        _senderIdMeta,
        senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('flags')) {
      context.handle(
        _flagsMeta,
        flags.isAcceptableOrUnknown(data['flags']!, _flagsMeta),
      );
    } else if (isInserting) {
      context.missing(_flagsMeta);
    }
    if (data.containsKey('unknown_flags')) {
      context.handle(
        _unknownFlagsMeta,
        unknownFlags.isAcceptableOrUnknown(
          data['unknown_flags']!,
          _unknownFlagsMeta,
        ),
      );
    }
    if (data.containsKey('is_me_message')) {
      context.handle(
        _isMeMessageMeta,
        isMeMessage.isAcceptableOrUnknown(
          data['is_me_message']!,
          _isMeMessageMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_isMeMessageMeta);
    }
    if (data.containsKey('edit_state')) {
      context.handle(
        _editStateMeta,
        editState.isAcceptableOrUnknown(data['edit_state']!, _editStateMeta),
      );
    } else if (isInserting) {
      context.missing(_editStateMeta);
    }
    if (data.containsKey('last_edit_timestamp')) {
      context.handle(
        _lastEditTimestampMeta,
        lastEditTimestamp.isAcceptableOrUnknown(
          data['last_edit_timestamp']!,
          _lastEditTimestampMeta,
        ),
      );
    }
    if (data.containsKey('display_recipient_cleared')) {
      context.handle(
        _displayRecipientClearedMeta,
        displayRecipientCleared.isAcceptableOrUnknown(
          data['display_recipient_cleared']!,
          _displayRecipientClearedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayRecipientClearedMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('tracked')) {
      context.handle(
        _trackedMeta,
        tracked.isAcceptableOrUnknown(data['tracked']!, _trackedMeta),
      );
    } else if (isInserting) {
      context.missing(_trackedMeta);
    }
    if (data.containsKey('body_bytes')) {
      context.handle(
        _bodyBytesMeta,
        bodyBytes.isAcceptableOrUnknown(data['body_bytes']!, _bodyBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyBytesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, id};
  @override
  StoredMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredMessage(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      channelId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}channel_id'],
      ),
      topic: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}topic'],
      ),
      topicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}topic_key'],
      ),
      dmKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dm_key'],
      ),
      senderId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sender_id'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      flags: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}flags'],
      )!,
      unknownFlags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unknown_flags'],
      ),
      isMeMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_me_message'],
      )!,
      editState: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}edit_state'],
      )!,
      lastEditTimestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_edit_timestamp'],
      ),
      displayRecipientCleared: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}display_recipient_cleared'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      tracked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}tracked'],
      )!,
      bodyBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}body_bytes'],
      )!,
    );
  }

  @override
  $StoredMessagesTable createAlias(String alias) {
    return $StoredMessagesTable(attachedDatabase, alias);
  }

  @override
  bool get withoutRowId => true;
}

class StoredMessage extends DataClass implements Insertable<StoredMessage> {
  final int accountId;
  final int id;
  final int? channelId;
  final String? topic;
  final String? topicKey;
  final String? dmKey;
  final int senderId;
  final int timestamp;
  final int flags;
  final String? unknownFlags;
  final bool isMeMessage;
  final int editState;
  final int? lastEditTimestamp;
  final bool displayRecipientCleared;
  final int epoch;
  final bool tracked;
  final int bodyBytes;
  const StoredMessage({
    required this.accountId,
    required this.id,
    this.channelId,
    this.topic,
    this.topicKey,
    this.dmKey,
    required this.senderId,
    required this.timestamp,
    required this.flags,
    this.unknownFlags,
    required this.isMeMessage,
    required this.editState,
    this.lastEditTimestamp,
    required this.displayRecipientCleared,
    required this.epoch,
    required this.tracked,
    required this.bodyBytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || channelId != null) {
      map['channel_id'] = Variable<int>(channelId);
    }
    if (!nullToAbsent || topic != null) {
      map['topic'] = Variable<String>(topic);
    }
    if (!nullToAbsent || topicKey != null) {
      map['topic_key'] = Variable<String>(topicKey);
    }
    if (!nullToAbsent || dmKey != null) {
      map['dm_key'] = Variable<String>(dmKey);
    }
    map['sender_id'] = Variable<int>(senderId);
    map['timestamp'] = Variable<int>(timestamp);
    map['flags'] = Variable<int>(flags);
    if (!nullToAbsent || unknownFlags != null) {
      map['unknown_flags'] = Variable<String>(unknownFlags);
    }
    map['is_me_message'] = Variable<bool>(isMeMessage);
    map['edit_state'] = Variable<int>(editState);
    if (!nullToAbsent || lastEditTimestamp != null) {
      map['last_edit_timestamp'] = Variable<int>(lastEditTimestamp);
    }
    map['display_recipient_cleared'] = Variable<bool>(displayRecipientCleared);
    map['epoch'] = Variable<int>(epoch);
    map['tracked'] = Variable<bool>(tracked);
    map['body_bytes'] = Variable<int>(bodyBytes);
    return map;
  }

  StoredMessagesCompanion toCompanion(bool nullToAbsent) {
    return StoredMessagesCompanion(
      accountId: Value(accountId),
      id: Value(id),
      channelId: channelId == null && nullToAbsent
          ? const Value.absent()
          : Value(channelId),
      topic: topic == null && nullToAbsent
          ? const Value.absent()
          : Value(topic),
      topicKey: topicKey == null && nullToAbsent
          ? const Value.absent()
          : Value(topicKey),
      dmKey: dmKey == null && nullToAbsent
          ? const Value.absent()
          : Value(dmKey),
      senderId: Value(senderId),
      timestamp: Value(timestamp),
      flags: Value(flags),
      unknownFlags: unknownFlags == null && nullToAbsent
          ? const Value.absent()
          : Value(unknownFlags),
      isMeMessage: Value(isMeMessage),
      editState: Value(editState),
      lastEditTimestamp: lastEditTimestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(lastEditTimestamp),
      displayRecipientCleared: Value(displayRecipientCleared),
      epoch: Value(epoch),
      tracked: Value(tracked),
      bodyBytes: Value(bodyBytes),
    );
  }

  factory StoredMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredMessage(
      accountId: serializer.fromJson<int>(json['accountId']),
      id: serializer.fromJson<int>(json['id']),
      channelId: serializer.fromJson<int?>(json['channelId']),
      topic: serializer.fromJson<String?>(json['topic']),
      topicKey: serializer.fromJson<String?>(json['topicKey']),
      dmKey: serializer.fromJson<String?>(json['dmKey']),
      senderId: serializer.fromJson<int>(json['senderId']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      flags: serializer.fromJson<int>(json['flags']),
      unknownFlags: serializer.fromJson<String?>(json['unknownFlags']),
      isMeMessage: serializer.fromJson<bool>(json['isMeMessage']),
      editState: serializer.fromJson<int>(json['editState']),
      lastEditTimestamp: serializer.fromJson<int?>(json['lastEditTimestamp']),
      displayRecipientCleared: serializer.fromJson<bool>(
        json['displayRecipientCleared'],
      ),
      epoch: serializer.fromJson<int>(json['epoch']),
      tracked: serializer.fromJson<bool>(json['tracked']),
      bodyBytes: serializer.fromJson<int>(json['bodyBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'id': serializer.toJson<int>(id),
      'channelId': serializer.toJson<int?>(channelId),
      'topic': serializer.toJson<String?>(topic),
      'topicKey': serializer.toJson<String?>(topicKey),
      'dmKey': serializer.toJson<String?>(dmKey),
      'senderId': serializer.toJson<int>(senderId),
      'timestamp': serializer.toJson<int>(timestamp),
      'flags': serializer.toJson<int>(flags),
      'unknownFlags': serializer.toJson<String?>(unknownFlags),
      'isMeMessage': serializer.toJson<bool>(isMeMessage),
      'editState': serializer.toJson<int>(editState),
      'lastEditTimestamp': serializer.toJson<int?>(lastEditTimestamp),
      'displayRecipientCleared': serializer.toJson<bool>(
        displayRecipientCleared,
      ),
      'epoch': serializer.toJson<int>(epoch),
      'tracked': serializer.toJson<bool>(tracked),
      'bodyBytes': serializer.toJson<int>(bodyBytes),
    };
  }

  StoredMessage copyWith({
    int? accountId,
    int? id,
    Value<int?> channelId = const Value.absent(),
    Value<String?> topic = const Value.absent(),
    Value<String?> topicKey = const Value.absent(),
    Value<String?> dmKey = const Value.absent(),
    int? senderId,
    int? timestamp,
    int? flags,
    Value<String?> unknownFlags = const Value.absent(),
    bool? isMeMessage,
    int? editState,
    Value<int?> lastEditTimestamp = const Value.absent(),
    bool? displayRecipientCleared,
    int? epoch,
    bool? tracked,
    int? bodyBytes,
  }) => StoredMessage(
    accountId: accountId ?? this.accountId,
    id: id ?? this.id,
    channelId: channelId.present ? channelId.value : this.channelId,
    topic: topic.present ? topic.value : this.topic,
    topicKey: topicKey.present ? topicKey.value : this.topicKey,
    dmKey: dmKey.present ? dmKey.value : this.dmKey,
    senderId: senderId ?? this.senderId,
    timestamp: timestamp ?? this.timestamp,
    flags: flags ?? this.flags,
    unknownFlags: unknownFlags.present ? unknownFlags.value : this.unknownFlags,
    isMeMessage: isMeMessage ?? this.isMeMessage,
    editState: editState ?? this.editState,
    lastEditTimestamp: lastEditTimestamp.present
        ? lastEditTimestamp.value
        : this.lastEditTimestamp,
    displayRecipientCleared:
        displayRecipientCleared ?? this.displayRecipientCleared,
    epoch: epoch ?? this.epoch,
    tracked: tracked ?? this.tracked,
    bodyBytes: bodyBytes ?? this.bodyBytes,
  );
  StoredMessage copyWithCompanion(StoredMessagesCompanion data) {
    return StoredMessage(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      id: data.id.present ? data.id.value : this.id,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      topic: data.topic.present ? data.topic.value : this.topic,
      topicKey: data.topicKey.present ? data.topicKey.value : this.topicKey,
      dmKey: data.dmKey.present ? data.dmKey.value : this.dmKey,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      flags: data.flags.present ? data.flags.value : this.flags,
      unknownFlags: data.unknownFlags.present
          ? data.unknownFlags.value
          : this.unknownFlags,
      isMeMessage: data.isMeMessage.present
          ? data.isMeMessage.value
          : this.isMeMessage,
      editState: data.editState.present ? data.editState.value : this.editState,
      lastEditTimestamp: data.lastEditTimestamp.present
          ? data.lastEditTimestamp.value
          : this.lastEditTimestamp,
      displayRecipientCleared: data.displayRecipientCleared.present
          ? data.displayRecipientCleared.value
          : this.displayRecipientCleared,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      tracked: data.tracked.present ? data.tracked.value : this.tracked,
      bodyBytes: data.bodyBytes.present ? data.bodyBytes.value : this.bodyBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredMessage(')
          ..write('accountId: $accountId, ')
          ..write('id: $id, ')
          ..write('channelId: $channelId, ')
          ..write('topic: $topic, ')
          ..write('topicKey: $topicKey, ')
          ..write('dmKey: $dmKey, ')
          ..write('senderId: $senderId, ')
          ..write('timestamp: $timestamp, ')
          ..write('flags: $flags, ')
          ..write('unknownFlags: $unknownFlags, ')
          ..write('isMeMessage: $isMeMessage, ')
          ..write('editState: $editState, ')
          ..write('lastEditTimestamp: $lastEditTimestamp, ')
          ..write('displayRecipientCleared: $displayRecipientCleared, ')
          ..write('epoch: $epoch, ')
          ..write('tracked: $tracked, ')
          ..write('bodyBytes: $bodyBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    id,
    channelId,
    topic,
    topicKey,
    dmKey,
    senderId,
    timestamp,
    flags,
    unknownFlags,
    isMeMessage,
    editState,
    lastEditTimestamp,
    displayRecipientCleared,
    epoch,
    tracked,
    bodyBytes,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredMessage &&
          other.accountId == this.accountId &&
          other.id == this.id &&
          other.channelId == this.channelId &&
          other.topic == this.topic &&
          other.topicKey == this.topicKey &&
          other.dmKey == this.dmKey &&
          other.senderId == this.senderId &&
          other.timestamp == this.timestamp &&
          other.flags == this.flags &&
          other.unknownFlags == this.unknownFlags &&
          other.isMeMessage == this.isMeMessage &&
          other.editState == this.editState &&
          other.lastEditTimestamp == this.lastEditTimestamp &&
          other.displayRecipientCleared == this.displayRecipientCleared &&
          other.epoch == this.epoch &&
          other.tracked == this.tracked &&
          other.bodyBytes == this.bodyBytes);
}

class StoredMessagesCompanion extends UpdateCompanion<StoredMessage> {
  final Value<int> accountId;
  final Value<int> id;
  final Value<int?> channelId;
  final Value<String?> topic;
  final Value<String?> topicKey;
  final Value<String?> dmKey;
  final Value<int> senderId;
  final Value<int> timestamp;
  final Value<int> flags;
  final Value<String?> unknownFlags;
  final Value<bool> isMeMessage;
  final Value<int> editState;
  final Value<int?> lastEditTimestamp;
  final Value<bool> displayRecipientCleared;
  final Value<int> epoch;
  final Value<bool> tracked;
  final Value<int> bodyBytes;
  const StoredMessagesCompanion({
    this.accountId = const Value.absent(),
    this.id = const Value.absent(),
    this.channelId = const Value.absent(),
    this.topic = const Value.absent(),
    this.topicKey = const Value.absent(),
    this.dmKey = const Value.absent(),
    this.senderId = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.flags = const Value.absent(),
    this.unknownFlags = const Value.absent(),
    this.isMeMessage = const Value.absent(),
    this.editState = const Value.absent(),
    this.lastEditTimestamp = const Value.absent(),
    this.displayRecipientCleared = const Value.absent(),
    this.epoch = const Value.absent(),
    this.tracked = const Value.absent(),
    this.bodyBytes = const Value.absent(),
  });
  StoredMessagesCompanion.insert({
    required int accountId,
    required int id,
    this.channelId = const Value.absent(),
    this.topic = const Value.absent(),
    this.topicKey = const Value.absent(),
    this.dmKey = const Value.absent(),
    required int senderId,
    required int timestamp,
    required int flags,
    this.unknownFlags = const Value.absent(),
    required bool isMeMessage,
    required int editState,
    this.lastEditTimestamp = const Value.absent(),
    required bool displayRecipientCleared,
    required int epoch,
    required bool tracked,
    required int bodyBytes,
  }) : accountId = Value(accountId),
       id = Value(id),
       senderId = Value(senderId),
       timestamp = Value(timestamp),
       flags = Value(flags),
       isMeMessage = Value(isMeMessage),
       editState = Value(editState),
       displayRecipientCleared = Value(displayRecipientCleared),
       epoch = Value(epoch),
       tracked = Value(tracked),
       bodyBytes = Value(bodyBytes);
  static Insertable<StoredMessage> custom({
    Expression<int>? accountId,
    Expression<int>? id,
    Expression<int>? channelId,
    Expression<String>? topic,
    Expression<String>? topicKey,
    Expression<String>? dmKey,
    Expression<int>? senderId,
    Expression<int>? timestamp,
    Expression<int>? flags,
    Expression<String>? unknownFlags,
    Expression<bool>? isMeMessage,
    Expression<int>? editState,
    Expression<int>? lastEditTimestamp,
    Expression<bool>? displayRecipientCleared,
    Expression<int>? epoch,
    Expression<bool>? tracked,
    Expression<int>? bodyBytes,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (id != null) 'id': id,
      if (channelId != null) 'channel_id': channelId,
      if (topic != null) 'topic': topic,
      if (topicKey != null) 'topic_key': topicKey,
      if (dmKey != null) 'dm_key': dmKey,
      if (senderId != null) 'sender_id': senderId,
      if (timestamp != null) 'timestamp': timestamp,
      if (flags != null) 'flags': flags,
      if (unknownFlags != null) 'unknown_flags': unknownFlags,
      if (isMeMessage != null) 'is_me_message': isMeMessage,
      if (editState != null) 'edit_state': editState,
      if (lastEditTimestamp != null) 'last_edit_timestamp': lastEditTimestamp,
      if (displayRecipientCleared != null)
        'display_recipient_cleared': displayRecipientCleared,
      if (epoch != null) 'epoch': epoch,
      if (tracked != null) 'tracked': tracked,
      if (bodyBytes != null) 'body_bytes': bodyBytes,
    });
  }

  StoredMessagesCompanion copyWith({
    Value<int>? accountId,
    Value<int>? id,
    Value<int?>? channelId,
    Value<String?>? topic,
    Value<String?>? topicKey,
    Value<String?>? dmKey,
    Value<int>? senderId,
    Value<int>? timestamp,
    Value<int>? flags,
    Value<String?>? unknownFlags,
    Value<bool>? isMeMessage,
    Value<int>? editState,
    Value<int?>? lastEditTimestamp,
    Value<bool>? displayRecipientCleared,
    Value<int>? epoch,
    Value<bool>? tracked,
    Value<int>? bodyBytes,
  }) {
    return StoredMessagesCompanion(
      accountId: accountId ?? this.accountId,
      id: id ?? this.id,
      channelId: channelId ?? this.channelId,
      topic: topic ?? this.topic,
      topicKey: topicKey ?? this.topicKey,
      dmKey: dmKey ?? this.dmKey,
      senderId: senderId ?? this.senderId,
      timestamp: timestamp ?? this.timestamp,
      flags: flags ?? this.flags,
      unknownFlags: unknownFlags ?? this.unknownFlags,
      isMeMessage: isMeMessage ?? this.isMeMessage,
      editState: editState ?? this.editState,
      lastEditTimestamp: lastEditTimestamp ?? this.lastEditTimestamp,
      displayRecipientCleared:
          displayRecipientCleared ?? this.displayRecipientCleared,
      epoch: epoch ?? this.epoch,
      tracked: tracked ?? this.tracked,
      bodyBytes: bodyBytes ?? this.bodyBytes,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<int>(channelId.value);
    }
    if (topic.present) {
      map['topic'] = Variable<String>(topic.value);
    }
    if (topicKey.present) {
      map['topic_key'] = Variable<String>(topicKey.value);
    }
    if (dmKey.present) {
      map['dm_key'] = Variable<String>(dmKey.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<int>(senderId.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (flags.present) {
      map['flags'] = Variable<int>(flags.value);
    }
    if (unknownFlags.present) {
      map['unknown_flags'] = Variable<String>(unknownFlags.value);
    }
    if (isMeMessage.present) {
      map['is_me_message'] = Variable<bool>(isMeMessage.value);
    }
    if (editState.present) {
      map['edit_state'] = Variable<int>(editState.value);
    }
    if (lastEditTimestamp.present) {
      map['last_edit_timestamp'] = Variable<int>(lastEditTimestamp.value);
    }
    if (displayRecipientCleared.present) {
      map['display_recipient_cleared'] = Variable<bool>(
        displayRecipientCleared.value,
      );
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (tracked.present) {
      map['tracked'] = Variable<bool>(tracked.value);
    }
    if (bodyBytes.present) {
      map['body_bytes'] = Variable<int>(bodyBytes.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StoredMessagesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('id: $id, ')
          ..write('channelId: $channelId, ')
          ..write('topic: $topic, ')
          ..write('topicKey: $topicKey, ')
          ..write('dmKey: $dmKey, ')
          ..write('senderId: $senderId, ')
          ..write('timestamp: $timestamp, ')
          ..write('flags: $flags, ')
          ..write('unknownFlags: $unknownFlags, ')
          ..write('isMeMessage: $isMeMessage, ')
          ..write('editState: $editState, ')
          ..write('lastEditTimestamp: $lastEditTimestamp, ')
          ..write('displayRecipientCleared: $displayRecipientCleared, ')
          ..write('epoch: $epoch, ')
          ..write('tracked: $tracked, ')
          ..write('bodyBytes: $bodyBytes')
          ..write(')'))
        .toString();
  }
}

class $StoredMessageBodiesTable extends StoredMessageBodies
    with TableInfo<$StoredMessageBodiesTable, StoredMessageBody> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StoredMessageBodiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _jsonMeta = const VerificationMeta('json');
  @override
  late final GeneratedColumn<Uint8List> json = GeneratedColumn<Uint8List>(
    'json',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [accountId, messageId, content, json];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stored_message_bodies';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredMessageBody> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('json')) {
      context.handle(
        _jsonMeta,
        json.isAcceptableOrUnknown(data['json']!, _jsonMeta),
      );
    } else if (isInserting) {
      context.missing(_jsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, messageId};
  @override
  StoredMessageBody map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredMessageBody(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_id'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      json: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}json'],
      )!,
    );
  }

  @override
  $StoredMessageBodiesTable createAlias(String alias) {
    return $StoredMessageBodiesTable(attachedDatabase, alias);
  }
}

class StoredMessageBody extends DataClass
    implements Insertable<StoredMessageBody> {
  final int accountId;
  final int messageId;
  final String content;
  final Uint8List json;
  const StoredMessageBody({
    required this.accountId,
    required this.messageId,
    required this.content,
    required this.json,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['message_id'] = Variable<int>(messageId);
    map['content'] = Variable<String>(content);
    map['json'] = Variable<Uint8List>(json);
    return map;
  }

  StoredMessageBodiesCompanion toCompanion(bool nullToAbsent) {
    return StoredMessageBodiesCompanion(
      accountId: Value(accountId),
      messageId: Value(messageId),
      content: Value(content),
      json: Value(json),
    );
  }

  factory StoredMessageBody.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredMessageBody(
      accountId: serializer.fromJson<int>(json['accountId']),
      messageId: serializer.fromJson<int>(json['messageId']),
      content: serializer.fromJson<String>(json['content']),
      json: serializer.fromJson<Uint8List>(json['json']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'messageId': serializer.toJson<int>(messageId),
      'content': serializer.toJson<String>(content),
      'json': serializer.toJson<Uint8List>(json),
    };
  }

  StoredMessageBody copyWith({
    int? accountId,
    int? messageId,
    String? content,
    Uint8List? json,
  }) => StoredMessageBody(
    accountId: accountId ?? this.accountId,
    messageId: messageId ?? this.messageId,
    content: content ?? this.content,
    json: json ?? this.json,
  );
  StoredMessageBody copyWithCompanion(StoredMessageBodiesCompanion data) {
    return StoredMessageBody(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      content: data.content.present ? data.content.value : this.content,
      json: data.json.present ? data.json.value : this.json,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredMessageBody(')
          ..write('accountId: $accountId, ')
          ..write('messageId: $messageId, ')
          ..write('content: $content, ')
          ..write('json: $json')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(accountId, messageId, content, $driftBlobEquality.hash(json));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredMessageBody &&
          other.accountId == this.accountId &&
          other.messageId == this.messageId &&
          other.content == this.content &&
          $driftBlobEquality.equals(other.json, this.json));
}

class StoredMessageBodiesCompanion extends UpdateCompanion<StoredMessageBody> {
  final Value<int> accountId;
  final Value<int> messageId;
  final Value<String> content;
  final Value<Uint8List> json;
  final Value<int> rowid;
  const StoredMessageBodiesCompanion({
    this.accountId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.content = const Value.absent(),
    this.json = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StoredMessageBodiesCompanion.insert({
    required int accountId,
    required int messageId,
    required String content,
    required Uint8List json,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       messageId = Value(messageId),
       content = Value(content),
       json = Value(json);
  static Insertable<StoredMessageBody> custom({
    Expression<int>? accountId,
    Expression<int>? messageId,
    Expression<String>? content,
    Expression<Uint8List>? json,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (messageId != null) 'message_id': messageId,
      if (content != null) 'content': content,
      if (json != null) 'json': json,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StoredMessageBodiesCompanion copyWith({
    Value<int>? accountId,
    Value<int>? messageId,
    Value<String>? content,
    Value<Uint8List>? json,
    Value<int>? rowid,
  }) {
    return StoredMessageBodiesCompanion(
      accountId: accountId ?? this.accountId,
      messageId: messageId ?? this.messageId,
      content: content ?? this.content,
      json: json ?? this.json,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (json.present) {
      map['json'] = Variable<Uint8List>(json.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StoredMessageBodiesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('messageId: $messageId, ')
          ..write('content: $content, ')
          ..write('json: $json, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StoredReactionsTable extends StoredReactions
    with TableInfo<$StoredReactionsTable, StoredReaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StoredReactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reactionTypeMeta = const VerificationMeta(
    'reactionType',
  );
  @override
  late final GeneratedColumn<String> reactionType = GeneratedColumn<String>(
    'reaction_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emojiCodeMeta = const VerificationMeta(
    'emojiCode',
  );
  @override
  late final GeneratedColumn<String> emojiCode = GeneratedColumn<String>(
    'emoji_code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emojiNameMeta = const VerificationMeta(
    'emojiName',
  );
  @override
  late final GeneratedColumn<String> emojiName = GeneratedColumn<String>(
    'emoji_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    messageId,
    seq,
    userId,
    reactionType,
    emojiCode,
    emojiName,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stored_reactions';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredReaction> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('reaction_type')) {
      context.handle(
        _reactionTypeMeta,
        reactionType.isAcceptableOrUnknown(
          data['reaction_type']!,
          _reactionTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reactionTypeMeta);
    }
    if (data.containsKey('emoji_code')) {
      context.handle(
        _emojiCodeMeta,
        emojiCode.isAcceptableOrUnknown(data['emoji_code']!, _emojiCodeMeta),
      );
    } else if (isInserting) {
      context.missing(_emojiCodeMeta);
    }
    if (data.containsKey('emoji_name')) {
      context.handle(
        _emojiNameMeta,
        emojiName.isAcceptableOrUnknown(data['emoji_name']!, _emojiNameMeta),
      );
    } else if (isInserting) {
      context.missing(_emojiNameMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, messageId, userId, reactionType, emojiCode},
  ];
  @override
  StoredReaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredReaction(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      reactionType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reaction_type'],
      )!,
      emojiCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}emoji_code'],
      )!,
      emojiName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}emoji_name'],
      )!,
    );
  }

  @override
  $StoredReactionsTable createAlias(String alias) {
    return $StoredReactionsTable(attachedDatabase, alias);
  }
}

class StoredReaction extends DataClass implements Insertable<StoredReaction> {
  final int accountId;
  final int messageId;
  final int seq;
  final int userId;
  final String reactionType;
  final String emojiCode;
  final String emojiName;
  const StoredReaction({
    required this.accountId,
    required this.messageId,
    required this.seq,
    required this.userId,
    required this.reactionType,
    required this.emojiCode,
    required this.emojiName,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['message_id'] = Variable<int>(messageId);
    map['seq'] = Variable<int>(seq);
    map['user_id'] = Variable<int>(userId);
    map['reaction_type'] = Variable<String>(reactionType);
    map['emoji_code'] = Variable<String>(emojiCode);
    map['emoji_name'] = Variable<String>(emojiName);
    return map;
  }

  StoredReactionsCompanion toCompanion(bool nullToAbsent) {
    return StoredReactionsCompanion(
      accountId: Value(accountId),
      messageId: Value(messageId),
      seq: Value(seq),
      userId: Value(userId),
      reactionType: Value(reactionType),
      emojiCode: Value(emojiCode),
      emojiName: Value(emojiName),
    );
  }

  factory StoredReaction.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredReaction(
      accountId: serializer.fromJson<int>(json['accountId']),
      messageId: serializer.fromJson<int>(json['messageId']),
      seq: serializer.fromJson<int>(json['seq']),
      userId: serializer.fromJson<int>(json['userId']),
      reactionType: serializer.fromJson<String>(json['reactionType']),
      emojiCode: serializer.fromJson<String>(json['emojiCode']),
      emojiName: serializer.fromJson<String>(json['emojiName']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'messageId': serializer.toJson<int>(messageId),
      'seq': serializer.toJson<int>(seq),
      'userId': serializer.toJson<int>(userId),
      'reactionType': serializer.toJson<String>(reactionType),
      'emojiCode': serializer.toJson<String>(emojiCode),
      'emojiName': serializer.toJson<String>(emojiName),
    };
  }

  StoredReaction copyWith({
    int? accountId,
    int? messageId,
    int? seq,
    int? userId,
    String? reactionType,
    String? emojiCode,
    String? emojiName,
  }) => StoredReaction(
    accountId: accountId ?? this.accountId,
    messageId: messageId ?? this.messageId,
    seq: seq ?? this.seq,
    userId: userId ?? this.userId,
    reactionType: reactionType ?? this.reactionType,
    emojiCode: emojiCode ?? this.emojiCode,
    emojiName: emojiName ?? this.emojiName,
  );
  StoredReaction copyWithCompanion(StoredReactionsCompanion data) {
    return StoredReaction(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      seq: data.seq.present ? data.seq.value : this.seq,
      userId: data.userId.present ? data.userId.value : this.userId,
      reactionType: data.reactionType.present
          ? data.reactionType.value
          : this.reactionType,
      emojiCode: data.emojiCode.present ? data.emojiCode.value : this.emojiCode,
      emojiName: data.emojiName.present ? data.emojiName.value : this.emojiName,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredReaction(')
          ..write('accountId: $accountId, ')
          ..write('messageId: $messageId, ')
          ..write('seq: $seq, ')
          ..write('userId: $userId, ')
          ..write('reactionType: $reactionType, ')
          ..write('emojiCode: $emojiCode, ')
          ..write('emojiName: $emojiName')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    messageId,
    seq,
    userId,
    reactionType,
    emojiCode,
    emojiName,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredReaction &&
          other.accountId == this.accountId &&
          other.messageId == this.messageId &&
          other.seq == this.seq &&
          other.userId == this.userId &&
          other.reactionType == this.reactionType &&
          other.emojiCode == this.emojiCode &&
          other.emojiName == this.emojiName);
}

class StoredReactionsCompanion extends UpdateCompanion<StoredReaction> {
  final Value<int> accountId;
  final Value<int> messageId;
  final Value<int> seq;
  final Value<int> userId;
  final Value<String> reactionType;
  final Value<String> emojiCode;
  final Value<String> emojiName;
  final Value<int> rowid;
  const StoredReactionsCompanion({
    this.accountId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.seq = const Value.absent(),
    this.userId = const Value.absent(),
    this.reactionType = const Value.absent(),
    this.emojiCode = const Value.absent(),
    this.emojiName = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StoredReactionsCompanion.insert({
    required int accountId,
    required int messageId,
    required int seq,
    required int userId,
    required String reactionType,
    required String emojiCode,
    required String emojiName,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       messageId = Value(messageId),
       seq = Value(seq),
       userId = Value(userId),
       reactionType = Value(reactionType),
       emojiCode = Value(emojiCode),
       emojiName = Value(emojiName);
  static Insertable<StoredReaction> custom({
    Expression<int>? accountId,
    Expression<int>? messageId,
    Expression<int>? seq,
    Expression<int>? userId,
    Expression<String>? reactionType,
    Expression<String>? emojiCode,
    Expression<String>? emojiName,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (messageId != null) 'message_id': messageId,
      if (seq != null) 'seq': seq,
      if (userId != null) 'user_id': userId,
      if (reactionType != null) 'reaction_type': reactionType,
      if (emojiCode != null) 'emoji_code': emojiCode,
      if (emojiName != null) 'emoji_name': emojiName,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StoredReactionsCompanion copyWith({
    Value<int>? accountId,
    Value<int>? messageId,
    Value<int>? seq,
    Value<int>? userId,
    Value<String>? reactionType,
    Value<String>? emojiCode,
    Value<String>? emojiName,
    Value<int>? rowid,
  }) {
    return StoredReactionsCompanion(
      accountId: accountId ?? this.accountId,
      messageId: messageId ?? this.messageId,
      seq: seq ?? this.seq,
      userId: userId ?? this.userId,
      reactionType: reactionType ?? this.reactionType,
      emojiCode: emojiCode ?? this.emojiCode,
      emojiName: emojiName ?? this.emojiName,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (reactionType.present) {
      map['reaction_type'] = Variable<String>(reactionType.value);
    }
    if (emojiCode.present) {
      map['emoji_code'] = Variable<String>(emojiCode.value);
    }
    if (emojiName.present) {
      map['emoji_name'] = Variable<String>(emojiName.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StoredReactionsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('messageId: $messageId, ')
          ..write('seq: $seq, ')
          ..write('userId: $userId, ')
          ..write('reactionType: $reactionType, ')
          ..write('emojiCode: $emojiCode, ')
          ..write('emojiName: $emojiName, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StoredSubmessagesTable extends StoredSubmessages
    with TableInfo<$StoredSubmessagesTable, StoredSubmessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StoredSubmessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _submessageIdMeta = const VerificationMeta(
    'submessageId',
  );
  @override
  late final GeneratedColumn<int> submessageId = GeneratedColumn<int>(
    'submessage_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderIdMeta = const VerificationMeta(
    'senderId',
  );
  @override
  late final GeneratedColumn<int> senderId = GeneratedColumn<int>(
    'sender_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _msgTypeMeta = const VerificationMeta(
    'msgType',
  );
  @override
  late final GeneratedColumn<String> msgType = GeneratedColumn<String>(
    'msg_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    submessageId,
    messageId,
    senderId,
    msgType,
    content,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stored_submessages';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredSubmessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('submessage_id')) {
      context.handle(
        _submessageIdMeta,
        submessageId.isAcceptableOrUnknown(
          data['submessage_id']!,
          _submessageIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_submessageIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('sender_id')) {
      context.handle(
        _senderIdMeta,
        senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('msg_type')) {
      context.handle(
        _msgTypeMeta,
        msgType.isAcceptableOrUnknown(data['msg_type']!, _msgTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_msgTypeMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, submessageId};
  @override
  StoredSubmessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredSubmessage(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      submessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}submessage_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_id'],
      )!,
      senderId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sender_id'],
      )!,
      msgType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}msg_type'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
    );
  }

  @override
  $StoredSubmessagesTable createAlias(String alias) {
    return $StoredSubmessagesTable(attachedDatabase, alias);
  }
}

class StoredSubmessage extends DataClass
    implements Insertable<StoredSubmessage> {
  final int accountId;
  final int submessageId;
  final int messageId;
  final int senderId;
  final String msgType;
  final String content;
  const StoredSubmessage({
    required this.accountId,
    required this.submessageId,
    required this.messageId,
    required this.senderId,
    required this.msgType,
    required this.content,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['submessage_id'] = Variable<int>(submessageId);
    map['message_id'] = Variable<int>(messageId);
    map['sender_id'] = Variable<int>(senderId);
    map['msg_type'] = Variable<String>(msgType);
    map['content'] = Variable<String>(content);
    return map;
  }

  StoredSubmessagesCompanion toCompanion(bool nullToAbsent) {
    return StoredSubmessagesCompanion(
      accountId: Value(accountId),
      submessageId: Value(submessageId),
      messageId: Value(messageId),
      senderId: Value(senderId),
      msgType: Value(msgType),
      content: Value(content),
    );
  }

  factory StoredSubmessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredSubmessage(
      accountId: serializer.fromJson<int>(json['accountId']),
      submessageId: serializer.fromJson<int>(json['submessageId']),
      messageId: serializer.fromJson<int>(json['messageId']),
      senderId: serializer.fromJson<int>(json['senderId']),
      msgType: serializer.fromJson<String>(json['msgType']),
      content: serializer.fromJson<String>(json['content']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'submessageId': serializer.toJson<int>(submessageId),
      'messageId': serializer.toJson<int>(messageId),
      'senderId': serializer.toJson<int>(senderId),
      'msgType': serializer.toJson<String>(msgType),
      'content': serializer.toJson<String>(content),
    };
  }

  StoredSubmessage copyWith({
    int? accountId,
    int? submessageId,
    int? messageId,
    int? senderId,
    String? msgType,
    String? content,
  }) => StoredSubmessage(
    accountId: accountId ?? this.accountId,
    submessageId: submessageId ?? this.submessageId,
    messageId: messageId ?? this.messageId,
    senderId: senderId ?? this.senderId,
    msgType: msgType ?? this.msgType,
    content: content ?? this.content,
  );
  StoredSubmessage copyWithCompanion(StoredSubmessagesCompanion data) {
    return StoredSubmessage(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      submessageId: data.submessageId.present
          ? data.submessageId.value
          : this.submessageId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      msgType: data.msgType.present ? data.msgType.value : this.msgType,
      content: data.content.present ? data.content.value : this.content,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredSubmessage(')
          ..write('accountId: $accountId, ')
          ..write('submessageId: $submessageId, ')
          ..write('messageId: $messageId, ')
          ..write('senderId: $senderId, ')
          ..write('msgType: $msgType, ')
          ..write('content: $content')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    submessageId,
    messageId,
    senderId,
    msgType,
    content,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredSubmessage &&
          other.accountId == this.accountId &&
          other.submessageId == this.submessageId &&
          other.messageId == this.messageId &&
          other.senderId == this.senderId &&
          other.msgType == this.msgType &&
          other.content == this.content);
}

class StoredSubmessagesCompanion extends UpdateCompanion<StoredSubmessage> {
  final Value<int> accountId;
  final Value<int> submessageId;
  final Value<int> messageId;
  final Value<int> senderId;
  final Value<String> msgType;
  final Value<String> content;
  final Value<int> rowid;
  const StoredSubmessagesCompanion({
    this.accountId = const Value.absent(),
    this.submessageId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.senderId = const Value.absent(),
    this.msgType = const Value.absent(),
    this.content = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StoredSubmessagesCompanion.insert({
    required int accountId,
    required int submessageId,
    required int messageId,
    required int senderId,
    required String msgType,
    required String content,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       submessageId = Value(submessageId),
       messageId = Value(messageId),
       senderId = Value(senderId),
       msgType = Value(msgType),
       content = Value(content);
  static Insertable<StoredSubmessage> custom({
    Expression<int>? accountId,
    Expression<int>? submessageId,
    Expression<int>? messageId,
    Expression<int>? senderId,
    Expression<String>? msgType,
    Expression<String>? content,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (submessageId != null) 'submessage_id': submessageId,
      if (messageId != null) 'message_id': messageId,
      if (senderId != null) 'sender_id': senderId,
      if (msgType != null) 'msg_type': msgType,
      if (content != null) 'content': content,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StoredSubmessagesCompanion copyWith({
    Value<int>? accountId,
    Value<int>? submessageId,
    Value<int>? messageId,
    Value<int>? senderId,
    Value<String>? msgType,
    Value<String>? content,
    Value<int>? rowid,
  }) {
    return StoredSubmessagesCompanion(
      accountId: accountId ?? this.accountId,
      submessageId: submessageId ?? this.submessageId,
      messageId: messageId ?? this.messageId,
      senderId: senderId ?? this.senderId,
      msgType: msgType ?? this.msgType,
      content: content ?? this.content,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (submessageId.present) {
      map['submessage_id'] = Variable<int>(submessageId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<int>(senderId.value);
    }
    if (msgType.present) {
      map['msg_type'] = Variable<String>(msgType.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StoredSubmessagesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('submessageId: $submessageId, ')
          ..write('messageId: $messageId, ')
          ..write('senderId: $senderId, ')
          ..write('msgType: $msgType, ')
          ..write('content: $content, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CoverageIntervalsTable extends CoverageIntervals
    with TableInfo<$CoverageIntervalsTable, StoredCoverageInterval> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CoverageIntervalsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES message_db_accounts (account_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _narrowKeyMeta = const VerificationMeta(
    'narrowKey',
  );
  @override
  late final GeneratedColumn<String> narrowKey = GeneratedColumn<String>(
    'narrow_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _loMeta = const VerificationMeta('lo');
  @override
  late final GeneratedColumn<int> lo = GeneratedColumn<int>(
    'lo',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hiMeta = const VerificationMeta('hi');
  @override
  late final GeneratedColumn<int> hi = GeneratedColumn<int>(
    'hi',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _trackedMeta = const VerificationMeta(
    'tracked',
  );
  @override
  late final GeneratedColumn<bool> tracked = GeneratedColumn<bool>(
    'tracked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("tracked" IN (0, 1))',
    ),
  );
  static const VerificationMeta _verifiedAtMeta = const VerificationMeta(
    'verifiedAt',
  );
  @override
  late final GeneratedColumn<int> verifiedAt = GeneratedColumn<int>(
    'verified_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    narrowKey,
    lo,
    hi,
    epoch,
    tracked,
    verifiedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'coverage_intervals';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredCoverageInterval> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('narrow_key')) {
      context.handle(
        _narrowKeyMeta,
        narrowKey.isAcceptableOrUnknown(data['narrow_key']!, _narrowKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_narrowKeyMeta);
    }
    if (data.containsKey('lo')) {
      context.handle(_loMeta, lo.isAcceptableOrUnknown(data['lo']!, _loMeta));
    } else if (isInserting) {
      context.missing(_loMeta);
    }
    if (data.containsKey('hi')) {
      context.handle(_hiMeta, hi.isAcceptableOrUnknown(data['hi']!, _hiMeta));
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('tracked')) {
      context.handle(
        _trackedMeta,
        tracked.isAcceptableOrUnknown(data['tracked']!, _trackedMeta),
      );
    } else if (isInserting) {
      context.missing(_trackedMeta);
    }
    if (data.containsKey('verified_at')) {
      context.handle(
        _verifiedAtMeta,
        verifiedAt.isAcceptableOrUnknown(data['verified_at']!, _verifiedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_verifiedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, narrowKey, lo};
  @override
  StoredCoverageInterval map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredCoverageInterval(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      narrowKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}narrow_key'],
      )!,
      lo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}lo'],
      )!,
      hi: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}hi'],
      ),
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      tracked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}tracked'],
      )!,
      verifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}verified_at'],
      )!,
    );
  }

  @override
  $CoverageIntervalsTable createAlias(String alias) {
    return $CoverageIntervalsTable(attachedDatabase, alias);
  }
}

class StoredCoverageInterval extends DataClass
    implements Insertable<StoredCoverageInterval> {
  final int accountId;
  final String narrowKey;
  final int lo;
  final int? hi;
  final int epoch;
  final bool tracked;
  final int verifiedAt;
  const StoredCoverageInterval({
    required this.accountId,
    required this.narrowKey,
    required this.lo,
    this.hi,
    required this.epoch,
    required this.tracked,
    required this.verifiedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['narrow_key'] = Variable<String>(narrowKey);
    map['lo'] = Variable<int>(lo);
    if (!nullToAbsent || hi != null) {
      map['hi'] = Variable<int>(hi);
    }
    map['epoch'] = Variable<int>(epoch);
    map['tracked'] = Variable<bool>(tracked);
    map['verified_at'] = Variable<int>(verifiedAt);
    return map;
  }

  CoverageIntervalsCompanion toCompanion(bool nullToAbsent) {
    return CoverageIntervalsCompanion(
      accountId: Value(accountId),
      narrowKey: Value(narrowKey),
      lo: Value(lo),
      hi: hi == null && nullToAbsent ? const Value.absent() : Value(hi),
      epoch: Value(epoch),
      tracked: Value(tracked),
      verifiedAt: Value(verifiedAt),
    );
  }

  factory StoredCoverageInterval.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredCoverageInterval(
      accountId: serializer.fromJson<int>(json['accountId']),
      narrowKey: serializer.fromJson<String>(json['narrowKey']),
      lo: serializer.fromJson<int>(json['lo']),
      hi: serializer.fromJson<int?>(json['hi']),
      epoch: serializer.fromJson<int>(json['epoch']),
      tracked: serializer.fromJson<bool>(json['tracked']),
      verifiedAt: serializer.fromJson<int>(json['verifiedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'narrowKey': serializer.toJson<String>(narrowKey),
      'lo': serializer.toJson<int>(lo),
      'hi': serializer.toJson<int?>(hi),
      'epoch': serializer.toJson<int>(epoch),
      'tracked': serializer.toJson<bool>(tracked),
      'verifiedAt': serializer.toJson<int>(verifiedAt),
    };
  }

  StoredCoverageInterval copyWith({
    int? accountId,
    String? narrowKey,
    int? lo,
    Value<int?> hi = const Value.absent(),
    int? epoch,
    bool? tracked,
    int? verifiedAt,
  }) => StoredCoverageInterval(
    accountId: accountId ?? this.accountId,
    narrowKey: narrowKey ?? this.narrowKey,
    lo: lo ?? this.lo,
    hi: hi.present ? hi.value : this.hi,
    epoch: epoch ?? this.epoch,
    tracked: tracked ?? this.tracked,
    verifiedAt: verifiedAt ?? this.verifiedAt,
  );
  StoredCoverageInterval copyWithCompanion(CoverageIntervalsCompanion data) {
    return StoredCoverageInterval(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      narrowKey: data.narrowKey.present ? data.narrowKey.value : this.narrowKey,
      lo: data.lo.present ? data.lo.value : this.lo,
      hi: data.hi.present ? data.hi.value : this.hi,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      tracked: data.tracked.present ? data.tracked.value : this.tracked,
      verifiedAt: data.verifiedAt.present
          ? data.verifiedAt.value
          : this.verifiedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredCoverageInterval(')
          ..write('accountId: $accountId, ')
          ..write('narrowKey: $narrowKey, ')
          ..write('lo: $lo, ')
          ..write('hi: $hi, ')
          ..write('epoch: $epoch, ')
          ..write('tracked: $tracked, ')
          ..write('verifiedAt: $verifiedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(accountId, narrowKey, lo, hi, epoch, tracked, verifiedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredCoverageInterval &&
          other.accountId == this.accountId &&
          other.narrowKey == this.narrowKey &&
          other.lo == this.lo &&
          other.hi == this.hi &&
          other.epoch == this.epoch &&
          other.tracked == this.tracked &&
          other.verifiedAt == this.verifiedAt);
}

class CoverageIntervalsCompanion
    extends UpdateCompanion<StoredCoverageInterval> {
  final Value<int> accountId;
  final Value<String> narrowKey;
  final Value<int> lo;
  final Value<int?> hi;
  final Value<int> epoch;
  final Value<bool> tracked;
  final Value<int> verifiedAt;
  final Value<int> rowid;
  const CoverageIntervalsCompanion({
    this.accountId = const Value.absent(),
    this.narrowKey = const Value.absent(),
    this.lo = const Value.absent(),
    this.hi = const Value.absent(),
    this.epoch = const Value.absent(),
    this.tracked = const Value.absent(),
    this.verifiedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CoverageIntervalsCompanion.insert({
    required int accountId,
    required String narrowKey,
    required int lo,
    this.hi = const Value.absent(),
    required int epoch,
    required bool tracked,
    required int verifiedAt,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       narrowKey = Value(narrowKey),
       lo = Value(lo),
       epoch = Value(epoch),
       tracked = Value(tracked),
       verifiedAt = Value(verifiedAt);
  static Insertable<StoredCoverageInterval> custom({
    Expression<int>? accountId,
    Expression<String>? narrowKey,
    Expression<int>? lo,
    Expression<int>? hi,
    Expression<int>? epoch,
    Expression<bool>? tracked,
    Expression<int>? verifiedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (narrowKey != null) 'narrow_key': narrowKey,
      if (lo != null) 'lo': lo,
      if (hi != null) 'hi': hi,
      if (epoch != null) 'epoch': epoch,
      if (tracked != null) 'tracked': tracked,
      if (verifiedAt != null) 'verified_at': verifiedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CoverageIntervalsCompanion copyWith({
    Value<int>? accountId,
    Value<String>? narrowKey,
    Value<int>? lo,
    Value<int?>? hi,
    Value<int>? epoch,
    Value<bool>? tracked,
    Value<int>? verifiedAt,
    Value<int>? rowid,
  }) {
    return CoverageIntervalsCompanion(
      accountId: accountId ?? this.accountId,
      narrowKey: narrowKey ?? this.narrowKey,
      lo: lo ?? this.lo,
      hi: hi ?? this.hi,
      epoch: epoch ?? this.epoch,
      tracked: tracked ?? this.tracked,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (narrowKey.present) {
      map['narrow_key'] = Variable<String>(narrowKey.value);
    }
    if (lo.present) {
      map['lo'] = Variable<int>(lo.value);
    }
    if (hi.present) {
      map['hi'] = Variable<int>(hi.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (tracked.present) {
      map['tracked'] = Variable<bool>(tracked.value);
    }
    if (verifiedAt.present) {
      map['verified_at'] = Variable<int>(verifiedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CoverageIntervalsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('narrowKey: $narrowKey, ')
          ..write('lo: $lo, ')
          ..write('hi: $hi, ')
          ..write('epoch: $epoch, ')
          ..write('tracked: $tracked, ')
          ..write('verifiedAt: $verifiedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessageDbChannelsTable extends MessageDbChannels
    with TableInfo<$MessageDbChannelsTable, MessageDbChannel> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageDbChannelsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES message_db_accounts (account_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _channelIdMeta = const VerificationMeta(
    'channelId',
  );
  @override
  late final GeneratedColumn<int> channelId = GeneratedColumn<int>(
    'channel_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _historyPublicToSubscribersMeta =
      const VerificationMeta('historyPublicToSubscribers');
  @override
  late final GeneratedColumn<bool> historyPublicToSubscribers =
      GeneratedColumn<bool>(
        'history_public_to_subscribers',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: true,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("history_public_to_subscribers" IN (0, 1))',
        ),
      );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    channelId,
    historyPublicToSubscribers,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_db_channels';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageDbChannel> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('channel_id')) {
      context.handle(
        _channelIdMeta,
        channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta),
      );
    } else if (isInserting) {
      context.missing(_channelIdMeta);
    }
    if (data.containsKey('history_public_to_subscribers')) {
      context.handle(
        _historyPublicToSubscribersMeta,
        historyPublicToSubscribers.isAcceptableOrUnknown(
          data['history_public_to_subscribers']!,
          _historyPublicToSubscribersMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_historyPublicToSubscribersMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, channelId};
  @override
  MessageDbChannel map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageDbChannel(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      channelId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}channel_id'],
      )!,
      historyPublicToSubscribers: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}history_public_to_subscribers'],
      )!,
    );
  }

  @override
  $MessageDbChannelsTable createAlias(String alias) {
    return $MessageDbChannelsTable(attachedDatabase, alias);
  }
}

class MessageDbChannel extends DataClass
    implements Insertable<MessageDbChannel> {
  final int accountId;
  final int channelId;
  final bool historyPublicToSubscribers;
  const MessageDbChannel({
    required this.accountId,
    required this.channelId,
    required this.historyPublicToSubscribers,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['channel_id'] = Variable<int>(channelId);
    map['history_public_to_subscribers'] = Variable<bool>(
      historyPublicToSubscribers,
    );
    return map;
  }

  MessageDbChannelsCompanion toCompanion(bool nullToAbsent) {
    return MessageDbChannelsCompanion(
      accountId: Value(accountId),
      channelId: Value(channelId),
      historyPublicToSubscribers: Value(historyPublicToSubscribers),
    );
  }

  factory MessageDbChannel.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageDbChannel(
      accountId: serializer.fromJson<int>(json['accountId']),
      channelId: serializer.fromJson<int>(json['channelId']),
      historyPublicToSubscribers: serializer.fromJson<bool>(
        json['historyPublicToSubscribers'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'channelId': serializer.toJson<int>(channelId),
      'historyPublicToSubscribers': serializer.toJson<bool>(
        historyPublicToSubscribers,
      ),
    };
  }

  MessageDbChannel copyWith({
    int? accountId,
    int? channelId,
    bool? historyPublicToSubscribers,
  }) => MessageDbChannel(
    accountId: accountId ?? this.accountId,
    channelId: channelId ?? this.channelId,
    historyPublicToSubscribers:
        historyPublicToSubscribers ?? this.historyPublicToSubscribers,
  );
  MessageDbChannel copyWithCompanion(MessageDbChannelsCompanion data) {
    return MessageDbChannel(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      historyPublicToSubscribers: data.historyPublicToSubscribers.present
          ? data.historyPublicToSubscribers.value
          : this.historyPublicToSubscribers,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageDbChannel(')
          ..write('accountId: $accountId, ')
          ..write('channelId: $channelId, ')
          ..write('historyPublicToSubscribers: $historyPublicToSubscribers')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(accountId, channelId, historyPublicToSubscribers);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageDbChannel &&
          other.accountId == this.accountId &&
          other.channelId == this.channelId &&
          other.historyPublicToSubscribers == this.historyPublicToSubscribers);
}

class MessageDbChannelsCompanion extends UpdateCompanion<MessageDbChannel> {
  final Value<int> accountId;
  final Value<int> channelId;
  final Value<bool> historyPublicToSubscribers;
  final Value<int> rowid;
  const MessageDbChannelsCompanion({
    this.accountId = const Value.absent(),
    this.channelId = const Value.absent(),
    this.historyPublicToSubscribers = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageDbChannelsCompanion.insert({
    required int accountId,
    required int channelId,
    required bool historyPublicToSubscribers,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       channelId = Value(channelId),
       historyPublicToSubscribers = Value(historyPublicToSubscribers);
  static Insertable<MessageDbChannel> custom({
    Expression<int>? accountId,
    Expression<int>? channelId,
    Expression<bool>? historyPublicToSubscribers,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (channelId != null) 'channel_id': channelId,
      if (historyPublicToSubscribers != null)
        'history_public_to_subscribers': historyPublicToSubscribers,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageDbChannelsCompanion copyWith({
    Value<int>? accountId,
    Value<int>? channelId,
    Value<bool>? historyPublicToSubscribers,
    Value<int>? rowid,
  }) {
    return MessageDbChannelsCompanion(
      accountId: accountId ?? this.accountId,
      channelId: channelId ?? this.channelId,
      historyPublicToSubscribers:
          historyPublicToSubscribers ?? this.historyPublicToSubscribers,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<int>(channelId.value);
    }
    if (historyPublicToSubscribers.present) {
      map['history_public_to_subscribers'] = Variable<bool>(
        historyPublicToSubscribers.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageDbChannelsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('channelId: $channelId, ')
          ..write('historyPublicToSubscribers: $historyPublicToSubscribers, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ServerSnapshotsTable extends ServerSnapshots
    with TableInfo<$ServerSnapshotsTable, ServerSnapshot> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerSnapshotsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _realmUrlMeta = const VerificationMeta(
    'realmUrl',
  );
  @override
  late final GeneratedColumn<String> realmUrl = GeneratedColumn<String>(
    'realm_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _queueIdMeta = const VerificationMeta(
    'queueId',
  );
  @override
  late final GeneratedColumn<String> queueId = GeneratedColumn<String>(
    'queue_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastEventIdMeta = const VerificationMeta(
    'lastEventId',
  );
  @override
  late final GeneratedColumn<int> lastEventId = GeneratedColumn<int>(
    'last_event_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _appVersionMeta = const VerificationMeta(
    'appVersion',
  );
  @override
  late final GeneratedColumn<String> appVersion = GeneratedColumn<String>(
    'app_version',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _eventLogTruncatedMeta = const VerificationMeta(
    'eventLogTruncated',
  );
  @override
  late final GeneratedColumn<bool> eventLogTruncated = GeneratedColumn<bool>(
    'event_log_truncated',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("event_log_truncated" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    realmUrl,
    userId,
    queueId,
    lastEventId,
    appVersion,
    timestamp,
    eventLogTruncated,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'server_snapshots';
  @override
  VerificationContext validateIntegrity(
    Insertable<ServerSnapshot> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('realm_url')) {
      context.handle(
        _realmUrlMeta,
        realmUrl.isAcceptableOrUnknown(data['realm_url']!, _realmUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_realmUrlMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('queue_id')) {
      context.handle(
        _queueIdMeta,
        queueId.isAcceptableOrUnknown(data['queue_id']!, _queueIdMeta),
      );
    } else if (isInserting) {
      context.missing(_queueIdMeta);
    }
    if (data.containsKey('last_event_id')) {
      context.handle(
        _lastEventIdMeta,
        lastEventId.isAcceptableOrUnknown(
          data['last_event_id']!,
          _lastEventIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastEventIdMeta);
    }
    if (data.containsKey('app_version')) {
      context.handle(
        _appVersionMeta,
        appVersion.isAcceptableOrUnknown(data['app_version']!, _appVersionMeta),
      );
    } else if (isInserting) {
      context.missing(_appVersionMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('event_log_truncated')) {
      context.handle(
        _eventLogTruncatedMeta,
        eventLogTruncated.isAcceptableOrUnknown(
          data['event_log_truncated']!,
          _eventLogTruncatedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  ServerSnapshot map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerSnapshot(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      realmUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}realm_url'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      queueId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}queue_id'],
      )!,
      lastEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_event_id'],
      )!,
      appVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}app_version'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      eventLogTruncated: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}event_log_truncated'],
      )!,
    );
  }

  @override
  $ServerSnapshotsTable createAlias(String alias) {
    return $ServerSnapshotsTable(attachedDatabase, alias);
  }
}

class ServerSnapshot extends DataClass implements Insertable<ServerSnapshot> {
  final int accountId;
  final String realmUrl;
  final int userId;

  /// The ID of the event queue the snapshot was registered with.
  final String queueId;

  /// The ID of the last event received on the queue and recorded here.
  final int lastEventId;

  /// The app version that stored the snapshot, as "version+buildNumber".
  final String appVersion;

  /// When the snapshot was registered, in seconds since the Unix epoch.
  final int timestamp;

  /// Whether events on this queue were left out of [ServerEventBatches].
  final bool eventLogTruncated;
  const ServerSnapshot({
    required this.accountId,
    required this.realmUrl,
    required this.userId,
    required this.queueId,
    required this.lastEventId,
    required this.appVersion,
    required this.timestamp,
    required this.eventLogTruncated,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['realm_url'] = Variable<String>(realmUrl);
    map['user_id'] = Variable<int>(userId);
    map['queue_id'] = Variable<String>(queueId);
    map['last_event_id'] = Variable<int>(lastEventId);
    map['app_version'] = Variable<String>(appVersion);
    map['timestamp'] = Variable<int>(timestamp);
    map['event_log_truncated'] = Variable<bool>(eventLogTruncated);
    return map;
  }

  ServerSnapshotsCompanion toCompanion(bool nullToAbsent) {
    return ServerSnapshotsCompanion(
      accountId: Value(accountId),
      realmUrl: Value(realmUrl),
      userId: Value(userId),
      queueId: Value(queueId),
      lastEventId: Value(lastEventId),
      appVersion: Value(appVersion),
      timestamp: Value(timestamp),
      eventLogTruncated: Value(eventLogTruncated),
    );
  }

  factory ServerSnapshot.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerSnapshot(
      accountId: serializer.fromJson<int>(json['accountId']),
      realmUrl: serializer.fromJson<String>(json['realmUrl']),
      userId: serializer.fromJson<int>(json['userId']),
      queueId: serializer.fromJson<String>(json['queueId']),
      lastEventId: serializer.fromJson<int>(json['lastEventId']),
      appVersion: serializer.fromJson<String>(json['appVersion']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      eventLogTruncated: serializer.fromJson<bool>(json['eventLogTruncated']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'realmUrl': serializer.toJson<String>(realmUrl),
      'userId': serializer.toJson<int>(userId),
      'queueId': serializer.toJson<String>(queueId),
      'lastEventId': serializer.toJson<int>(lastEventId),
      'appVersion': serializer.toJson<String>(appVersion),
      'timestamp': serializer.toJson<int>(timestamp),
      'eventLogTruncated': serializer.toJson<bool>(eventLogTruncated),
    };
  }

  ServerSnapshot copyWith({
    int? accountId,
    String? realmUrl,
    int? userId,
    String? queueId,
    int? lastEventId,
    String? appVersion,
    int? timestamp,
    bool? eventLogTruncated,
  }) => ServerSnapshot(
    accountId: accountId ?? this.accountId,
    realmUrl: realmUrl ?? this.realmUrl,
    userId: userId ?? this.userId,
    queueId: queueId ?? this.queueId,
    lastEventId: lastEventId ?? this.lastEventId,
    appVersion: appVersion ?? this.appVersion,
    timestamp: timestamp ?? this.timestamp,
    eventLogTruncated: eventLogTruncated ?? this.eventLogTruncated,
  );
  ServerSnapshot copyWithCompanion(ServerSnapshotsCompanion data) {
    return ServerSnapshot(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      realmUrl: data.realmUrl.present ? data.realmUrl.value : this.realmUrl,
      userId: data.userId.present ? data.userId.value : this.userId,
      queueId: data.queueId.present ? data.queueId.value : this.queueId,
      lastEventId: data.lastEventId.present
          ? data.lastEventId.value
          : this.lastEventId,
      appVersion: data.appVersion.present
          ? data.appVersion.value
          : this.appVersion,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      eventLogTruncated: data.eventLogTruncated.present
          ? data.eventLogTruncated.value
          : this.eventLogTruncated,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ServerSnapshot(')
          ..write('accountId: $accountId, ')
          ..write('realmUrl: $realmUrl, ')
          ..write('userId: $userId, ')
          ..write('queueId: $queueId, ')
          ..write('lastEventId: $lastEventId, ')
          ..write('appVersion: $appVersion, ')
          ..write('timestamp: $timestamp, ')
          ..write('eventLogTruncated: $eventLogTruncated')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    realmUrl,
    userId,
    queueId,
    lastEventId,
    appVersion,
    timestamp,
    eventLogTruncated,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ServerSnapshot &&
          other.accountId == this.accountId &&
          other.realmUrl == this.realmUrl &&
          other.userId == this.userId &&
          other.queueId == this.queueId &&
          other.lastEventId == this.lastEventId &&
          other.appVersion == this.appVersion &&
          other.timestamp == this.timestamp &&
          other.eventLogTruncated == this.eventLogTruncated);
}

class ServerSnapshotsCompanion extends UpdateCompanion<ServerSnapshot> {
  final Value<int> accountId;
  final Value<String> realmUrl;
  final Value<int> userId;
  final Value<String> queueId;
  final Value<int> lastEventId;
  final Value<String> appVersion;
  final Value<int> timestamp;
  final Value<bool> eventLogTruncated;
  const ServerSnapshotsCompanion({
    this.accountId = const Value.absent(),
    this.realmUrl = const Value.absent(),
    this.userId = const Value.absent(),
    this.queueId = const Value.absent(),
    this.lastEventId = const Value.absent(),
    this.appVersion = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.eventLogTruncated = const Value.absent(),
  });
  ServerSnapshotsCompanion.insert({
    this.accountId = const Value.absent(),
    required String realmUrl,
    required int userId,
    required String queueId,
    required int lastEventId,
    required String appVersion,
    required int timestamp,
    this.eventLogTruncated = const Value.absent(),
  }) : realmUrl = Value(realmUrl),
       userId = Value(userId),
       queueId = Value(queueId),
       lastEventId = Value(lastEventId),
       appVersion = Value(appVersion),
       timestamp = Value(timestamp);
  static Insertable<ServerSnapshot> custom({
    Expression<int>? accountId,
    Expression<String>? realmUrl,
    Expression<int>? userId,
    Expression<String>? queueId,
    Expression<int>? lastEventId,
    Expression<String>? appVersion,
    Expression<int>? timestamp,
    Expression<bool>? eventLogTruncated,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (realmUrl != null) 'realm_url': realmUrl,
      if (userId != null) 'user_id': userId,
      if (queueId != null) 'queue_id': queueId,
      if (lastEventId != null) 'last_event_id': lastEventId,
      if (appVersion != null) 'app_version': appVersion,
      if (timestamp != null) 'timestamp': timestamp,
      if (eventLogTruncated != null) 'event_log_truncated': eventLogTruncated,
    });
  }

  ServerSnapshotsCompanion copyWith({
    Value<int>? accountId,
    Value<String>? realmUrl,
    Value<int>? userId,
    Value<String>? queueId,
    Value<int>? lastEventId,
    Value<String>? appVersion,
    Value<int>? timestamp,
    Value<bool>? eventLogTruncated,
  }) {
    return ServerSnapshotsCompanion(
      accountId: accountId ?? this.accountId,
      realmUrl: realmUrl ?? this.realmUrl,
      userId: userId ?? this.userId,
      queueId: queueId ?? this.queueId,
      lastEventId: lastEventId ?? this.lastEventId,
      appVersion: appVersion ?? this.appVersion,
      timestamp: timestamp ?? this.timestamp,
      eventLogTruncated: eventLogTruncated ?? this.eventLogTruncated,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (realmUrl.present) {
      map['realm_url'] = Variable<String>(realmUrl.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (queueId.present) {
      map['queue_id'] = Variable<String>(queueId.value);
    }
    if (lastEventId.present) {
      map['last_event_id'] = Variable<int>(lastEventId.value);
    }
    if (appVersion.present) {
      map['app_version'] = Variable<String>(appVersion.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (eventLogTruncated.present) {
      map['event_log_truncated'] = Variable<bool>(eventLogTruncated.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServerSnapshotsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('realmUrl: $realmUrl, ')
          ..write('userId: $userId, ')
          ..write('queueId: $queueId, ')
          ..write('lastEventId: $lastEventId, ')
          ..write('appVersion: $appVersion, ')
          ..write('timestamp: $timestamp, ')
          ..write('eventLogTruncated: $eventLogTruncated')
          ..write(')'))
        .toString();
  }
}

class $ServerSnapshotBlobsTable extends ServerSnapshotBlobs
    with TableInfo<$ServerSnapshotBlobsTable, ServerSnapshotBlob> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerSnapshotBlobsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES server_snapshots (account_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [accountId, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'server_snapshot_blobs';
  @override
  VerificationContext validateIntegrity(
    Insertable<ServerSnapshotBlob> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  ServerSnapshotBlob map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerSnapshotBlob(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $ServerSnapshotBlobsTable createAlias(String alias) {
    return $ServerSnapshotBlobsTable(attachedDatabase, alias);
  }
}

class ServerSnapshotBlob extends DataClass
    implements Insertable<ServerSnapshotBlob> {
  final int accountId;
  final Uint8List data;
  const ServerSnapshotBlob({required this.accountId, required this.data});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  ServerSnapshotBlobsCompanion toCompanion(bool nullToAbsent) {
    return ServerSnapshotBlobsCompanion(
      accountId: Value(accountId),
      data: Value(data),
    );
  }

  factory ServerSnapshotBlob.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerSnapshotBlob(
      accountId: serializer.fromJson<int>(json['accountId']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  ServerSnapshotBlob copyWith({int? accountId, Uint8List? data}) =>
      ServerSnapshotBlob(
        accountId: accountId ?? this.accountId,
        data: data ?? this.data,
      );
  ServerSnapshotBlob copyWithCompanion(ServerSnapshotBlobsCompanion data) {
    return ServerSnapshotBlob(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ServerSnapshotBlob(')
          ..write('accountId: $accountId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(accountId, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ServerSnapshotBlob &&
          other.accountId == this.accountId &&
          $driftBlobEquality.equals(other.data, this.data));
}

class ServerSnapshotBlobsCompanion extends UpdateCompanion<ServerSnapshotBlob> {
  final Value<int> accountId;
  final Value<Uint8List> data;
  const ServerSnapshotBlobsCompanion({
    this.accountId = const Value.absent(),
    this.data = const Value.absent(),
  });
  ServerSnapshotBlobsCompanion.insert({
    this.accountId = const Value.absent(),
    required Uint8List data,
  }) : data = Value(data);
  static Insertable<ServerSnapshotBlob> custom({
    Expression<int>? accountId,
    Expression<Uint8List>? data,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (data != null) 'data': data,
    });
  }

  ServerSnapshotBlobsCompanion copyWith({
    Value<int>? accountId,
    Value<Uint8List>? data,
  }) {
    return ServerSnapshotBlobsCompanion(
      accountId: accountId ?? this.accountId,
      data: data ?? this.data,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServerSnapshotBlobsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }
}

class $ServerEventBatchesTable extends ServerEventBatches
    with TableInfo<$ServerEventBatchesTable, ServerEventBatch> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerEventBatchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES server_snapshots (account_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _queueIdMeta = const VerificationMeta(
    'queueId',
  );
  @override
  late final GeneratedColumn<String> queueId = GeneratedColumn<String>(
    'queue_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastEventIdMeta = const VerificationMeta(
    'lastEventId',
  );
  @override
  late final GeneratedColumn<int> lastEventId = GeneratedColumn<int>(
    'last_event_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    queueId,
    lastEventId,
    data,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'server_event_batches';
  @override
  VerificationContext validateIntegrity(
    Insertable<ServerEventBatch> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('queue_id')) {
      context.handle(
        _queueIdMeta,
        queueId.isAcceptableOrUnknown(data['queue_id']!, _queueIdMeta),
      );
    } else if (isInserting) {
      context.missing(_queueIdMeta);
    }
    if (data.containsKey('last_event_id')) {
      context.handle(
        _lastEventIdMeta,
        lastEventId.isAcceptableOrUnknown(
          data['last_event_id']!,
          _lastEventIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastEventIdMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ServerEventBatch map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerEventBatch(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      queueId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}queue_id'],
      )!,
      lastEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_event_id'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $ServerEventBatchesTable createAlias(String alias) {
    return $ServerEventBatchesTable(attachedDatabase, alias);
  }
}

class ServerEventBatch extends DataClass
    implements Insertable<ServerEventBatch> {
  final int id;
  final int accountId;
  final String queueId;
  final int lastEventId;
  final Uint8List data;
  const ServerEventBatch({
    required this.id,
    required this.accountId,
    required this.queueId,
    required this.lastEventId,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['queue_id'] = Variable<String>(queueId);
    map['last_event_id'] = Variable<int>(lastEventId);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  ServerEventBatchesCompanion toCompanion(bool nullToAbsent) {
    return ServerEventBatchesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      queueId: Value(queueId),
      lastEventId: Value(lastEventId),
      data: Value(data),
    );
  }

  factory ServerEventBatch.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerEventBatch(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      queueId: serializer.fromJson<String>(json['queueId']),
      lastEventId: serializer.fromJson<int>(json['lastEventId']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'queueId': serializer.toJson<String>(queueId),
      'lastEventId': serializer.toJson<int>(lastEventId),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  ServerEventBatch copyWith({
    int? id,
    int? accountId,
    String? queueId,
    int? lastEventId,
    Uint8List? data,
  }) => ServerEventBatch(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    queueId: queueId ?? this.queueId,
    lastEventId: lastEventId ?? this.lastEventId,
    data: data ?? this.data,
  );
  ServerEventBatch copyWithCompanion(ServerEventBatchesCompanion data) {
    return ServerEventBatch(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      queueId: data.queueId.present ? data.queueId.value : this.queueId,
      lastEventId: data.lastEventId.present
          ? data.lastEventId.value
          : this.lastEventId,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ServerEventBatch(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('queueId: $queueId, ')
          ..write('lastEventId: $lastEventId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    queueId,
    lastEventId,
    $driftBlobEquality.hash(data),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ServerEventBatch &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.queueId == this.queueId &&
          other.lastEventId == this.lastEventId &&
          $driftBlobEquality.equals(other.data, this.data));
}

class ServerEventBatchesCompanion extends UpdateCompanion<ServerEventBatch> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<String> queueId;
  final Value<int> lastEventId;
  final Value<Uint8List> data;
  const ServerEventBatchesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.queueId = const Value.absent(),
    this.lastEventId = const Value.absent(),
    this.data = const Value.absent(),
  });
  ServerEventBatchesCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required String queueId,
    required int lastEventId,
    required Uint8List data,
  }) : accountId = Value(accountId),
       queueId = Value(queueId),
       lastEventId = Value(lastEventId),
       data = Value(data);
  static Insertable<ServerEventBatch> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<String>? queueId,
    Expression<int>? lastEventId,
    Expression<Uint8List>? data,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (queueId != null) 'queue_id': queueId,
      if (lastEventId != null) 'last_event_id': lastEventId,
      if (data != null) 'data': data,
    });
  }

  ServerEventBatchesCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<String>? queueId,
    Value<int>? lastEventId,
    Value<Uint8List>? data,
  }) {
    return ServerEventBatchesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      queueId: queueId ?? this.queueId,
      lastEventId: lastEventId ?? this.lastEventId,
      data: data ?? this.data,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (queueId.present) {
      map['queue_id'] = Variable<String>(queueId.value);
    }
    if (lastEventId.present) {
      map['last_event_id'] = Variable<int>(lastEventId.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServerEventBatchesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('queueId: $queueId, ')
          ..write('lastEventId: $lastEventId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }
}

abstract class _$MessageDatabase extends GeneratedDatabase {
  _$MessageDatabase(QueryExecutor e) : super(e);
  $MessageDatabaseManager get managers => $MessageDatabaseManager(this);
  late final $MessageDbAccountsTable messageDbAccounts =
      $MessageDbAccountsTable(this);
  late final $StoredMessagesTable storedMessages = $StoredMessagesTable(this);
  late final $StoredMessageBodiesTable storedMessageBodies =
      $StoredMessageBodiesTable(this);
  late final $StoredReactionsTable storedReactions = $StoredReactionsTable(
    this,
  );
  late final $StoredSubmessagesTable storedSubmessages =
      $StoredSubmessagesTable(this);
  late final $CoverageIntervalsTable coverageIntervals =
      $CoverageIntervalsTable(this);
  late final $MessageDbChannelsTable messageDbChannels =
      $MessageDbChannelsTable(this);
  late final $ServerSnapshotsTable serverSnapshots = $ServerSnapshotsTable(
    this,
  );
  late final $ServerSnapshotBlobsTable serverSnapshotBlobs =
      $ServerSnapshotBlobsTable(this);
  late final $ServerEventBatchesTable serverEventBatches =
      $ServerEventBatchesTable(this);
  late final Index idxSmTopic = Index(
    'idx_sm_topic',
    'CREATE INDEX idx_sm_topic ON stored_messages (account_id, channel_id, topic_key, id)',
  );
  late final Index idxSmChannel = Index(
    'idx_sm_channel',
    'CREATE INDEX idx_sm_channel ON stored_messages (account_id, channel_id, id)',
  );
  late final Index idxSmDm = Index(
    'idx_sm_dm',
    'CREATE INDEX idx_sm_dm ON stored_messages (account_id, dm_key, id)',
  );
  late final Index idxSrMessage = Index(
    'idx_sr_message',
    'CREATE INDEX idx_sr_message ON stored_reactions (account_id, message_id, seq)',
  );
  late final Index idxSsMessage = Index(
    'idx_ss_message',
    'CREATE INDEX idx_ss_message ON stored_submessages (account_id, message_id, submessage_id)',
  );
  late final Index idxServerEventBatchesAccountId = Index(
    'idx_server_event_batches_account_id',
    'CREATE INDEX idx_server_event_batches_account_id ON server_event_batches (account_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    messageDbAccounts,
    storedMessages,
    storedMessageBodies,
    storedReactions,
    storedSubmessages,
    coverageIntervals,
    messageDbChannels,
    serverSnapshots,
    serverSnapshotBlobs,
    serverEventBatches,
    idxSmTopic,
    idxSmChannel,
    idxSmDm,
    idxSrMessage,
    idxSsMessage,
    idxServerEventBatchesAccountId,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'message_db_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('stored_messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'message_db_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('coverage_intervals', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'message_db_accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('message_db_channels', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'server_snapshots',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('server_snapshot_blobs', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'server_snapshots',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('server_event_batches', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$MessageDbAccountsTableCreateCompanionBuilder =
    MessageDbAccountsCompanion Function({
      Value<int> accountId,
      required String realmUrl,
      required int userId,
      required int formatVersion,
      required int epoch,
      Value<String?> queueId,
      Value<int?> appliedThroughEventId,
      required int eventHighWater,
      Value<int?> lastLiveAt,
      Value<int> evictedBelowMessageId,
      Value<int> totalBodyBytes,
    });
typedef $$MessageDbAccountsTableUpdateCompanionBuilder =
    MessageDbAccountsCompanion Function({
      Value<int> accountId,
      Value<String> realmUrl,
      Value<int> userId,
      Value<int> formatVersion,
      Value<int> epoch,
      Value<String?> queueId,
      Value<int?> appliedThroughEventId,
      Value<int> eventHighWater,
      Value<int?> lastLiveAt,
      Value<int> evictedBelowMessageId,
      Value<int> totalBodyBytes,
    });

final class $$MessageDbAccountsTableReferences
    extends
        BaseReferences<
          _$MessageDatabase,
          $MessageDbAccountsTable,
          MessageDbAccount
        > {
  $$MessageDbAccountsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$StoredMessagesTable, List<StoredMessage>>
  _storedMessagesRefsTable(_$MessageDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.storedMessages,
        aliasName:
            'message_db_accounts__account_id__stored_messages__account_id',
      );

  $$StoredMessagesTableProcessedTableManager get storedMessagesRefs {
    final manager = $$StoredMessagesTableTableManager($_db, $_db.storedMessages)
        .filter(
          (f) =>
              f.accountId.accountId.sqlEquals($_itemColumn<int>('account_id')!),
        );

    final cache = $_typedResult.readTableOrNull(_storedMessagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $CoverageIntervalsTable,
    List<StoredCoverageInterval>
  >
  _coverageIntervalsRefsTable(_$MessageDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.coverageIntervals,
        aliasName:
            'message_db_accounts__account_id__coverage_intervals__account_id',
      );

  $$CoverageIntervalsTableProcessedTableManager get coverageIntervalsRefs {
    final manager =
        $$CoverageIntervalsTableTableManager(
          $_db,
          $_db.coverageIntervals,
        ).filter(
          (f) =>
              f.accountId.accountId.sqlEquals($_itemColumn<int>('account_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _coverageIntervalsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$MessageDbChannelsTable, List<MessageDbChannel>>
  _messageDbChannelsRefsTable(_$MessageDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.messageDbChannels,
        aliasName:
            'message_db_accounts__account_id__message_db_channels__account_id',
      );

  $$MessageDbChannelsTableProcessedTableManager get messageDbChannelsRefs {
    final manager =
        $$MessageDbChannelsTableTableManager(
          $_db,
          $_db.messageDbChannels,
        ).filter(
          (f) =>
              f.accountId.accountId.sqlEquals($_itemColumn<int>('account_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _messageDbChannelsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MessageDbAccountsTableFilterComposer
    extends Composer<_$MessageDatabase, $MessageDbAccountsTable> {
  $$MessageDbAccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get realmUrl => $composableBuilder(
    column: $table.realmUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get formatVersion => $composableBuilder(
    column: $table.formatVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get queueId => $composableBuilder(
    column: $table.queueId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get appliedThroughEventId => $composableBuilder(
    column: $table.appliedThroughEventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get eventHighWater => $composableBuilder(
    column: $table.eventHighWater,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastLiveAt => $composableBuilder(
    column: $table.lastLiveAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get evictedBelowMessageId => $composableBuilder(
    column: $table.evictedBelowMessageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalBodyBytes => $composableBuilder(
    column: $table.totalBodyBytes,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> storedMessagesRefs(
    Expression<bool> Function($$StoredMessagesTableFilterComposer f) f,
  ) {
    final $$StoredMessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.storedMessages,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$StoredMessagesTableFilterComposer(
            $db: $db,
            $table: $db.storedMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> coverageIntervalsRefs(
    Expression<bool> Function($$CoverageIntervalsTableFilterComposer f) f,
  ) {
    final $$CoverageIntervalsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.coverageIntervals,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CoverageIntervalsTableFilterComposer(
            $db: $db,
            $table: $db.coverageIntervals,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> messageDbChannelsRefs(
    Expression<bool> Function($$MessageDbChannelsTableFilterComposer f) f,
  ) {
    final $$MessageDbChannelsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.messageDbChannels,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageDbChannelsTableFilterComposer(
            $db: $db,
            $table: $db.messageDbChannels,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessageDbAccountsTableOrderingComposer
    extends Composer<_$MessageDatabase, $MessageDbAccountsTable> {
  $$MessageDbAccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get realmUrl => $composableBuilder(
    column: $table.realmUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get formatVersion => $composableBuilder(
    column: $table.formatVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get queueId => $composableBuilder(
    column: $table.queueId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get appliedThroughEventId => $composableBuilder(
    column: $table.appliedThroughEventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get eventHighWater => $composableBuilder(
    column: $table.eventHighWater,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastLiveAt => $composableBuilder(
    column: $table.lastLiveAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get evictedBelowMessageId => $composableBuilder(
    column: $table.evictedBelowMessageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalBodyBytes => $composableBuilder(
    column: $table.totalBodyBytes,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MessageDbAccountsTableAnnotationComposer
    extends Composer<_$MessageDatabase, $MessageDbAccountsTable> {
  $$MessageDbAccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get realmUrl =>
      $composableBuilder(column: $table.realmUrl, builder: (column) => column);

  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get formatVersion => $composableBuilder(
    column: $table.formatVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<String> get queueId =>
      $composableBuilder(column: $table.queueId, builder: (column) => column);

  GeneratedColumn<int> get appliedThroughEventId => $composableBuilder(
    column: $table.appliedThroughEventId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get eventHighWater => $composableBuilder(
    column: $table.eventHighWater,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastLiveAt => $composableBuilder(
    column: $table.lastLiveAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get evictedBelowMessageId => $composableBuilder(
    column: $table.evictedBelowMessageId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalBodyBytes => $composableBuilder(
    column: $table.totalBodyBytes,
    builder: (column) => column,
  );

  Expression<T> storedMessagesRefs<T extends Object>(
    Expression<T> Function($$StoredMessagesTableAnnotationComposer a) f,
  ) {
    final $$StoredMessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.storedMessages,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$StoredMessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.storedMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> coverageIntervalsRefs<T extends Object>(
    Expression<T> Function($$CoverageIntervalsTableAnnotationComposer a) f,
  ) {
    final $$CoverageIntervalsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.accountId,
          referencedTable: $db.coverageIntervals,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CoverageIntervalsTableAnnotationComposer(
                $db: $db,
                $table: $db.coverageIntervals,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> messageDbChannelsRefs<T extends Object>(
    Expression<T> Function($$MessageDbChannelsTableAnnotationComposer a) f,
  ) {
    final $$MessageDbChannelsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.accountId,
          referencedTable: $db.messageDbChannels,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$MessageDbChannelsTableAnnotationComposer(
                $db: $db,
                $table: $db.messageDbChannels,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$MessageDbAccountsTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $MessageDbAccountsTable,
          MessageDbAccount,
          $$MessageDbAccountsTableFilterComposer,
          $$MessageDbAccountsTableOrderingComposer,
          $$MessageDbAccountsTableAnnotationComposer,
          $$MessageDbAccountsTableCreateCompanionBuilder,
          $$MessageDbAccountsTableUpdateCompanionBuilder,
          (MessageDbAccount, $$MessageDbAccountsTableReferences),
          MessageDbAccount,
          PrefetchHooks Function({
            bool storedMessagesRefs,
            bool coverageIntervalsRefs,
            bool messageDbChannelsRefs,
          })
        > {
  $$MessageDbAccountsTableTableManager(
    _$MessageDatabase db,
    $MessageDbAccountsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageDbAccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageDbAccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageDbAccountsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<String> realmUrl = const Value.absent(),
                Value<int> userId = const Value.absent(),
                Value<int> formatVersion = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<String?> queueId = const Value.absent(),
                Value<int?> appliedThroughEventId = const Value.absent(),
                Value<int> eventHighWater = const Value.absent(),
                Value<int?> lastLiveAt = const Value.absent(),
                Value<int> evictedBelowMessageId = const Value.absent(),
                Value<int> totalBodyBytes = const Value.absent(),
              }) => MessageDbAccountsCompanion(
                accountId: accountId,
                realmUrl: realmUrl,
                userId: userId,
                formatVersion: formatVersion,
                epoch: epoch,
                queueId: queueId,
                appliedThroughEventId: appliedThroughEventId,
                eventHighWater: eventHighWater,
                lastLiveAt: lastLiveAt,
                evictedBelowMessageId: evictedBelowMessageId,
                totalBodyBytes: totalBodyBytes,
              ),
          createCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                required String realmUrl,
                required int userId,
                required int formatVersion,
                required int epoch,
                Value<String?> queueId = const Value.absent(),
                Value<int?> appliedThroughEventId = const Value.absent(),
                required int eventHighWater,
                Value<int?> lastLiveAt = const Value.absent(),
                Value<int> evictedBelowMessageId = const Value.absent(),
                Value<int> totalBodyBytes = const Value.absent(),
              }) => MessageDbAccountsCompanion.insert(
                accountId: accountId,
                realmUrl: realmUrl,
                userId: userId,
                formatVersion: formatVersion,
                epoch: epoch,
                queueId: queueId,
                appliedThroughEventId: appliedThroughEventId,
                eventHighWater: eventHighWater,
                lastLiveAt: lastLiveAt,
                evictedBelowMessageId: evictedBelowMessageId,
                totalBodyBytes: totalBodyBytes,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessageDbAccountsTable, MessageDbAccount>(table),
                  $$MessageDbAccountsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                storedMessagesRefs = false,
                coverageIntervalsRefs = false,
                messageDbChannelsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (storedMessagesRefs) db.storedMessages,
                    if (coverageIntervalsRefs) db.coverageIntervals,
                    if (messageDbChannelsRefs) db.messageDbChannels,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (storedMessagesRefs)
                        await $_getPrefetchedData<
                          MessageDbAccount,
                          $MessageDbAccountsTable,
                          StoredMessage
                        >(
                          currentTable: table,
                          referencedTable: $$MessageDbAccountsTableReferences
                              ._storedMessagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessageDbAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).storedMessagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.accountId,
                              ),
                          typedResults: items,
                        ),
                      if (coverageIntervalsRefs)
                        await $_getPrefetchedData<
                          MessageDbAccount,
                          $MessageDbAccountsTable,
                          StoredCoverageInterval
                        >(
                          currentTable: table,
                          referencedTable: $$MessageDbAccountsTableReferences
                              ._coverageIntervalsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessageDbAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).coverageIntervalsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.accountId,
                              ),
                          typedResults: items,
                        ),
                      if (messageDbChannelsRefs)
                        await $_getPrefetchedData<
                          MessageDbAccount,
                          $MessageDbAccountsTable,
                          MessageDbChannel
                        >(
                          currentTable: table,
                          referencedTable: $$MessageDbAccountsTableReferences
                              ._messageDbChannelsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessageDbAccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).messageDbChannelsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.accountId,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$MessageDbAccountsTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $MessageDbAccountsTable,
      MessageDbAccount,
      $$MessageDbAccountsTableFilterComposer,
      $$MessageDbAccountsTableOrderingComposer,
      $$MessageDbAccountsTableAnnotationComposer,
      $$MessageDbAccountsTableCreateCompanionBuilder,
      $$MessageDbAccountsTableUpdateCompanionBuilder,
      (MessageDbAccount, $$MessageDbAccountsTableReferences),
      MessageDbAccount,
      PrefetchHooks Function({
        bool storedMessagesRefs,
        bool coverageIntervalsRefs,
        bool messageDbChannelsRefs,
      })
    >;
typedef $$StoredMessagesTableCreateCompanionBuilder =
    StoredMessagesCompanion Function({
      required int accountId,
      required int id,
      Value<int?> channelId,
      Value<String?> topic,
      Value<String?> topicKey,
      Value<String?> dmKey,
      required int senderId,
      required int timestamp,
      required int flags,
      Value<String?> unknownFlags,
      required bool isMeMessage,
      required int editState,
      Value<int?> lastEditTimestamp,
      required bool displayRecipientCleared,
      required int epoch,
      required bool tracked,
      required int bodyBytes,
    });
typedef $$StoredMessagesTableUpdateCompanionBuilder =
    StoredMessagesCompanion Function({
      Value<int> accountId,
      Value<int> id,
      Value<int?> channelId,
      Value<String?> topic,
      Value<String?> topicKey,
      Value<String?> dmKey,
      Value<int> senderId,
      Value<int> timestamp,
      Value<int> flags,
      Value<String?> unknownFlags,
      Value<bool> isMeMessage,
      Value<int> editState,
      Value<int?> lastEditTimestamp,
      Value<bool> displayRecipientCleared,
      Value<int> epoch,
      Value<bool> tracked,
      Value<int> bodyBytes,
    });

final class $$StoredMessagesTableReferences
    extends
        BaseReferences<_$MessageDatabase, $StoredMessagesTable, StoredMessage> {
  $$StoredMessagesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MessageDbAccountsTable _accountIdTable(_$MessageDatabase db) =>
      db.messageDbAccounts.createAlias(
        'stored_messages__account_id__message_db_accounts__account_id',
      );

  $$MessageDbAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$MessageDbAccountsTableTableManager(
      $_db,
      $_db.messageDbAccounts,
    ).filter((f) => f.accountId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$StoredMessagesTableFilterComposer
    extends Composer<_$MessageDatabase, $StoredMessagesTable> {
  $$StoredMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get topic => $composableBuilder(
    column: $table.topic,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get topicKey => $composableBuilder(
    column: $table.topicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dmKey => $composableBuilder(
    column: $table.dmKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get flags => $composableBuilder(
    column: $table.flags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get unknownFlags => $composableBuilder(
    column: $table.unknownFlags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isMeMessage => $composableBuilder(
    column: $table.isMeMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get editState => $composableBuilder(
    column: $table.editState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastEditTimestamp => $composableBuilder(
    column: $table.lastEditTimestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get displayRecipientCleared => $composableBuilder(
    column: $table.displayRecipientCleared,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get tracked => $composableBuilder(
    column: $table.tracked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bodyBytes => $composableBuilder(
    column: $table.bodyBytes,
    builder: (column) => ColumnFilters(column),
  );

  $$MessageDbAccountsTableFilterComposer get accountId {
    final $$MessageDbAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.messageDbAccounts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageDbAccountsTableFilterComposer(
            $db: $db,
            $table: $db.messageDbAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$StoredMessagesTableOrderingComposer
    extends Composer<_$MessageDatabase, $StoredMessagesTable> {
  $$StoredMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get topic => $composableBuilder(
    column: $table.topic,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get topicKey => $composableBuilder(
    column: $table.topicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dmKey => $composableBuilder(
    column: $table.dmKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get flags => $composableBuilder(
    column: $table.flags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get unknownFlags => $composableBuilder(
    column: $table.unknownFlags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isMeMessage => $composableBuilder(
    column: $table.isMeMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get editState => $composableBuilder(
    column: $table.editState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastEditTimestamp => $composableBuilder(
    column: $table.lastEditTimestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get displayRecipientCleared => $composableBuilder(
    column: $table.displayRecipientCleared,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get tracked => $composableBuilder(
    column: $table.tracked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bodyBytes => $composableBuilder(
    column: $table.bodyBytes,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessageDbAccountsTableOrderingComposer get accountId {
    final $$MessageDbAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.messageDbAccounts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageDbAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.messageDbAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$StoredMessagesTableAnnotationComposer
    extends Composer<_$MessageDatabase, $StoredMessagesTable> {
  $$StoredMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<String> get topic =>
      $composableBuilder(column: $table.topic, builder: (column) => column);

  GeneratedColumn<String> get topicKey =>
      $composableBuilder(column: $table.topicKey, builder: (column) => column);

  GeneratedColumn<String> get dmKey =>
      $composableBuilder(column: $table.dmKey, builder: (column) => column);

  GeneratedColumn<int> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<int> get flags =>
      $composableBuilder(column: $table.flags, builder: (column) => column);

  GeneratedColumn<String> get unknownFlags => $composableBuilder(
    column: $table.unknownFlags,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isMeMessage => $composableBuilder(
    column: $table.isMeMessage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get editState =>
      $composableBuilder(column: $table.editState, builder: (column) => column);

  GeneratedColumn<int> get lastEditTimestamp => $composableBuilder(
    column: $table.lastEditTimestamp,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get displayRecipientCleared => $composableBuilder(
    column: $table.displayRecipientCleared,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<bool> get tracked =>
      $composableBuilder(column: $table.tracked, builder: (column) => column);

  GeneratedColumn<int> get bodyBytes =>
      $composableBuilder(column: $table.bodyBytes, builder: (column) => column);

  $$MessageDbAccountsTableAnnotationComposer get accountId {
    final $$MessageDbAccountsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.accountId,
          referencedTable: $db.messageDbAccounts,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$MessageDbAccountsTableAnnotationComposer(
                $db: $db,
                $table: $db.messageDbAccounts,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$StoredMessagesTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $StoredMessagesTable,
          StoredMessage,
          $$StoredMessagesTableFilterComposer,
          $$StoredMessagesTableOrderingComposer,
          $$StoredMessagesTableAnnotationComposer,
          $$StoredMessagesTableCreateCompanionBuilder,
          $$StoredMessagesTableUpdateCompanionBuilder,
          (StoredMessage, $$StoredMessagesTableReferences),
          StoredMessage,
          PrefetchHooks Function({bool accountId})
        > {
  $$StoredMessagesTableTableManager(
    _$MessageDatabase db,
    $StoredMessagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StoredMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StoredMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StoredMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> id = const Value.absent(),
                Value<int?> channelId = const Value.absent(),
                Value<String?> topic = const Value.absent(),
                Value<String?> topicKey = const Value.absent(),
                Value<String?> dmKey = const Value.absent(),
                Value<int> senderId = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
                Value<int> flags = const Value.absent(),
                Value<String?> unknownFlags = const Value.absent(),
                Value<bool> isMeMessage = const Value.absent(),
                Value<int> editState = const Value.absent(),
                Value<int?> lastEditTimestamp = const Value.absent(),
                Value<bool> displayRecipientCleared = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<bool> tracked = const Value.absent(),
                Value<int> bodyBytes = const Value.absent(),
              }) => StoredMessagesCompanion(
                accountId: accountId,
                id: id,
                channelId: channelId,
                topic: topic,
                topicKey: topicKey,
                dmKey: dmKey,
                senderId: senderId,
                timestamp: timestamp,
                flags: flags,
                unknownFlags: unknownFlags,
                isMeMessage: isMeMessage,
                editState: editState,
                lastEditTimestamp: lastEditTimestamp,
                displayRecipientCleared: displayRecipientCleared,
                epoch: epoch,
                tracked: tracked,
                bodyBytes: bodyBytes,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int id,
                Value<int?> channelId = const Value.absent(),
                Value<String?> topic = const Value.absent(),
                Value<String?> topicKey = const Value.absent(),
                Value<String?> dmKey = const Value.absent(),
                required int senderId,
                required int timestamp,
                required int flags,
                Value<String?> unknownFlags = const Value.absent(),
                required bool isMeMessage,
                required int editState,
                Value<int?> lastEditTimestamp = const Value.absent(),
                required bool displayRecipientCleared,
                required int epoch,
                required bool tracked,
                required int bodyBytes,
              }) => StoredMessagesCompanion.insert(
                accountId: accountId,
                id: id,
                channelId: channelId,
                topic: topic,
                topicKey: topicKey,
                dmKey: dmKey,
                senderId: senderId,
                timestamp: timestamp,
                flags: flags,
                unknownFlags: unknownFlags,
                isMeMessage: isMeMessage,
                editState: editState,
                lastEditTimestamp: lastEditTimestamp,
                displayRecipientCleared: displayRecipientCleared,
                epoch: epoch,
                tracked: tracked,
                bodyBytes: bodyBytes,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$StoredMessagesTable, StoredMessage>(table),
                  $$StoredMessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.accountId,
                        referencedTable: $$StoredMessagesTableReferences
                            ._accountIdTable(db),
                        referencedColumn: $$StoredMessagesTableReferences
                            ._accountIdTable(db)
                            .accountId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$StoredMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $StoredMessagesTable,
      StoredMessage,
      $$StoredMessagesTableFilterComposer,
      $$StoredMessagesTableOrderingComposer,
      $$StoredMessagesTableAnnotationComposer,
      $$StoredMessagesTableCreateCompanionBuilder,
      $$StoredMessagesTableUpdateCompanionBuilder,
      (StoredMessage, $$StoredMessagesTableReferences),
      StoredMessage,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$StoredMessageBodiesTableCreateCompanionBuilder =
    StoredMessageBodiesCompanion Function({
      required int accountId,
      required int messageId,
      required String content,
      required Uint8List json,
      Value<int> rowid,
    });
typedef $$StoredMessageBodiesTableUpdateCompanionBuilder =
    StoredMessageBodiesCompanion Function({
      Value<int> accountId,
      Value<int> messageId,
      Value<String> content,
      Value<Uint8List> json,
      Value<int> rowid,
    });

class $$StoredMessageBodiesTableFilterComposer
    extends Composer<_$MessageDatabase, $StoredMessageBodiesTable> {
  $$StoredMessageBodiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StoredMessageBodiesTableOrderingComposer
    extends Composer<_$MessageDatabase, $StoredMessageBodiesTable> {
  $$StoredMessageBodiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StoredMessageBodiesTableAnnotationComposer
    extends Composer<_$MessageDatabase, $StoredMessageBodiesTable> {
  $$StoredMessageBodiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<Uint8List> get json =>
      $composableBuilder(column: $table.json, builder: (column) => column);
}

class $$StoredMessageBodiesTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $StoredMessageBodiesTable,
          StoredMessageBody,
          $$StoredMessageBodiesTableFilterComposer,
          $$StoredMessageBodiesTableOrderingComposer,
          $$StoredMessageBodiesTableAnnotationComposer,
          $$StoredMessageBodiesTableCreateCompanionBuilder,
          $$StoredMessageBodiesTableUpdateCompanionBuilder,
          (
            StoredMessageBody,
            BaseReferences<
              _$MessageDatabase,
              $StoredMessageBodiesTable,
              StoredMessageBody
            >,
          ),
          StoredMessageBody,
          PrefetchHooks Function()
        > {
  $$StoredMessageBodiesTableTableManager(
    _$MessageDatabase db,
    $StoredMessageBodiesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StoredMessageBodiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StoredMessageBodiesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$StoredMessageBodiesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> messageId = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<Uint8List> json = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StoredMessageBodiesCompanion(
                accountId: accountId,
                messageId: messageId,
                content: content,
                json: json,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int messageId,
                required String content,
                required Uint8List json,
                Value<int> rowid = const Value.absent(),
              }) => StoredMessageBodiesCompanion.insert(
                accountId: accountId,
                messageId: messageId,
                content: content,
                json: json,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$StoredMessageBodiesTable, StoredMessageBody>(
                    table,
                  ),
                  BaseReferences<
                    _$MessageDatabase,
                    $StoredMessageBodiesTable,
                    StoredMessageBody
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StoredMessageBodiesTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $StoredMessageBodiesTable,
      StoredMessageBody,
      $$StoredMessageBodiesTableFilterComposer,
      $$StoredMessageBodiesTableOrderingComposer,
      $$StoredMessageBodiesTableAnnotationComposer,
      $$StoredMessageBodiesTableCreateCompanionBuilder,
      $$StoredMessageBodiesTableUpdateCompanionBuilder,
      (
        StoredMessageBody,
        BaseReferences<
          _$MessageDatabase,
          $StoredMessageBodiesTable,
          StoredMessageBody
        >,
      ),
      StoredMessageBody,
      PrefetchHooks Function()
    >;
typedef $$StoredReactionsTableCreateCompanionBuilder =
    StoredReactionsCompanion Function({
      required int accountId,
      required int messageId,
      required int seq,
      required int userId,
      required String reactionType,
      required String emojiCode,
      required String emojiName,
      Value<int> rowid,
    });
typedef $$StoredReactionsTableUpdateCompanionBuilder =
    StoredReactionsCompanion Function({
      Value<int> accountId,
      Value<int> messageId,
      Value<int> seq,
      Value<int> userId,
      Value<String> reactionType,
      Value<String> emojiCode,
      Value<String> emojiName,
      Value<int> rowid,
    });

class $$StoredReactionsTableFilterComposer
    extends Composer<_$MessageDatabase, $StoredReactionsTable> {
  $$StoredReactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reactionType => $composableBuilder(
    column: $table.reactionType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get emojiCode => $composableBuilder(
    column: $table.emojiCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get emojiName => $composableBuilder(
    column: $table.emojiName,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StoredReactionsTableOrderingComposer
    extends Composer<_$MessageDatabase, $StoredReactionsTable> {
  $$StoredReactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reactionType => $composableBuilder(
    column: $table.reactionType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get emojiCode => $composableBuilder(
    column: $table.emojiCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get emojiName => $composableBuilder(
    column: $table.emojiName,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StoredReactionsTableAnnotationComposer
    extends Composer<_$MessageDatabase, $StoredReactionsTable> {
  $$StoredReactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get reactionType => $composableBuilder(
    column: $table.reactionType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get emojiCode =>
      $composableBuilder(column: $table.emojiCode, builder: (column) => column);

  GeneratedColumn<String> get emojiName =>
      $composableBuilder(column: $table.emojiName, builder: (column) => column);
}

class $$StoredReactionsTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $StoredReactionsTable,
          StoredReaction,
          $$StoredReactionsTableFilterComposer,
          $$StoredReactionsTableOrderingComposer,
          $$StoredReactionsTableAnnotationComposer,
          $$StoredReactionsTableCreateCompanionBuilder,
          $$StoredReactionsTableUpdateCompanionBuilder,
          (
            StoredReaction,
            BaseReferences<
              _$MessageDatabase,
              $StoredReactionsTable,
              StoredReaction
            >,
          ),
          StoredReaction,
          PrefetchHooks Function()
        > {
  $$StoredReactionsTableTableManager(
    _$MessageDatabase db,
    $StoredReactionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StoredReactionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StoredReactionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StoredReactionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> messageId = const Value.absent(),
                Value<int> seq = const Value.absent(),
                Value<int> userId = const Value.absent(),
                Value<String> reactionType = const Value.absent(),
                Value<String> emojiCode = const Value.absent(),
                Value<String> emojiName = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StoredReactionsCompanion(
                accountId: accountId,
                messageId: messageId,
                seq: seq,
                userId: userId,
                reactionType: reactionType,
                emojiCode: emojiCode,
                emojiName: emojiName,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int messageId,
                required int seq,
                required int userId,
                required String reactionType,
                required String emojiCode,
                required String emojiName,
                Value<int> rowid = const Value.absent(),
              }) => StoredReactionsCompanion.insert(
                accountId: accountId,
                messageId: messageId,
                seq: seq,
                userId: userId,
                reactionType: reactionType,
                emojiCode: emojiCode,
                emojiName: emojiName,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$StoredReactionsTable, StoredReaction>(table),
                  BaseReferences<
                    _$MessageDatabase,
                    $StoredReactionsTable,
                    StoredReaction
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StoredReactionsTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $StoredReactionsTable,
      StoredReaction,
      $$StoredReactionsTableFilterComposer,
      $$StoredReactionsTableOrderingComposer,
      $$StoredReactionsTableAnnotationComposer,
      $$StoredReactionsTableCreateCompanionBuilder,
      $$StoredReactionsTableUpdateCompanionBuilder,
      (
        StoredReaction,
        BaseReferences<
          _$MessageDatabase,
          $StoredReactionsTable,
          StoredReaction
        >,
      ),
      StoredReaction,
      PrefetchHooks Function()
    >;
typedef $$StoredSubmessagesTableCreateCompanionBuilder =
    StoredSubmessagesCompanion Function({
      required int accountId,
      required int submessageId,
      required int messageId,
      required int senderId,
      required String msgType,
      required String content,
      Value<int> rowid,
    });
typedef $$StoredSubmessagesTableUpdateCompanionBuilder =
    StoredSubmessagesCompanion Function({
      Value<int> accountId,
      Value<int> submessageId,
      Value<int> messageId,
      Value<int> senderId,
      Value<String> msgType,
      Value<String> content,
      Value<int> rowid,
    });

class $$StoredSubmessagesTableFilterComposer
    extends Composer<_$MessageDatabase, $StoredSubmessagesTable> {
  $$StoredSubmessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get submessageId => $composableBuilder(
    column: $table.submessageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get msgType => $composableBuilder(
    column: $table.msgType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StoredSubmessagesTableOrderingComposer
    extends Composer<_$MessageDatabase, $StoredSubmessagesTable> {
  $$StoredSubmessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get submessageId => $composableBuilder(
    column: $table.submessageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get msgType => $composableBuilder(
    column: $table.msgType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StoredSubmessagesTableAnnotationComposer
    extends Composer<_$MessageDatabase, $StoredSubmessagesTable> {
  $$StoredSubmessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get submessageId => $composableBuilder(
    column: $table.submessageId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<int> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<String> get msgType =>
      $composableBuilder(column: $table.msgType, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);
}

class $$StoredSubmessagesTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $StoredSubmessagesTable,
          StoredSubmessage,
          $$StoredSubmessagesTableFilterComposer,
          $$StoredSubmessagesTableOrderingComposer,
          $$StoredSubmessagesTableAnnotationComposer,
          $$StoredSubmessagesTableCreateCompanionBuilder,
          $$StoredSubmessagesTableUpdateCompanionBuilder,
          (
            StoredSubmessage,
            BaseReferences<
              _$MessageDatabase,
              $StoredSubmessagesTable,
              StoredSubmessage
            >,
          ),
          StoredSubmessage,
          PrefetchHooks Function()
        > {
  $$StoredSubmessagesTableTableManager(
    _$MessageDatabase db,
    $StoredSubmessagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StoredSubmessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StoredSubmessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StoredSubmessagesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> submessageId = const Value.absent(),
                Value<int> messageId = const Value.absent(),
                Value<int> senderId = const Value.absent(),
                Value<String> msgType = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StoredSubmessagesCompanion(
                accountId: accountId,
                submessageId: submessageId,
                messageId: messageId,
                senderId: senderId,
                msgType: msgType,
                content: content,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int submessageId,
                required int messageId,
                required int senderId,
                required String msgType,
                required String content,
                Value<int> rowid = const Value.absent(),
              }) => StoredSubmessagesCompanion.insert(
                accountId: accountId,
                submessageId: submessageId,
                messageId: messageId,
                senderId: senderId,
                msgType: msgType,
                content: content,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$StoredSubmessagesTable, StoredSubmessage>(table),
                  BaseReferences<
                    _$MessageDatabase,
                    $StoredSubmessagesTable,
                    StoredSubmessage
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StoredSubmessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $StoredSubmessagesTable,
      StoredSubmessage,
      $$StoredSubmessagesTableFilterComposer,
      $$StoredSubmessagesTableOrderingComposer,
      $$StoredSubmessagesTableAnnotationComposer,
      $$StoredSubmessagesTableCreateCompanionBuilder,
      $$StoredSubmessagesTableUpdateCompanionBuilder,
      (
        StoredSubmessage,
        BaseReferences<
          _$MessageDatabase,
          $StoredSubmessagesTable,
          StoredSubmessage
        >,
      ),
      StoredSubmessage,
      PrefetchHooks Function()
    >;
typedef $$CoverageIntervalsTableCreateCompanionBuilder =
    CoverageIntervalsCompanion Function({
      required int accountId,
      required String narrowKey,
      required int lo,
      Value<int?> hi,
      required int epoch,
      required bool tracked,
      required int verifiedAt,
      Value<int> rowid,
    });
typedef $$CoverageIntervalsTableUpdateCompanionBuilder =
    CoverageIntervalsCompanion Function({
      Value<int> accountId,
      Value<String> narrowKey,
      Value<int> lo,
      Value<int?> hi,
      Value<int> epoch,
      Value<bool> tracked,
      Value<int> verifiedAt,
      Value<int> rowid,
    });

final class $$CoverageIntervalsTableReferences
    extends
        BaseReferences<
          _$MessageDatabase,
          $CoverageIntervalsTable,
          StoredCoverageInterval
        > {
  $$CoverageIntervalsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MessageDbAccountsTable _accountIdTable(_$MessageDatabase db) =>
      db.messageDbAccounts.createAlias(
        'coverage_intervals__account_id__message_db_accounts__account_id',
      );

  $$MessageDbAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$MessageDbAccountsTableTableManager(
      $_db,
      $_db.messageDbAccounts,
    ).filter((f) => f.accountId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CoverageIntervalsTableFilterComposer
    extends Composer<_$MessageDatabase, $CoverageIntervalsTable> {
  $$CoverageIntervalsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get narrowKey => $composableBuilder(
    column: $table.narrowKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lo => $composableBuilder(
    column: $table.lo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get hi => $composableBuilder(
    column: $table.hi,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get tracked => $composableBuilder(
    column: $table.tracked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get verifiedAt => $composableBuilder(
    column: $table.verifiedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$MessageDbAccountsTableFilterComposer get accountId {
    final $$MessageDbAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.messageDbAccounts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageDbAccountsTableFilterComposer(
            $db: $db,
            $table: $db.messageDbAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CoverageIntervalsTableOrderingComposer
    extends Composer<_$MessageDatabase, $CoverageIntervalsTable> {
  $$CoverageIntervalsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get narrowKey => $composableBuilder(
    column: $table.narrowKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lo => $composableBuilder(
    column: $table.lo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get hi => $composableBuilder(
    column: $table.hi,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get tracked => $composableBuilder(
    column: $table.tracked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get verifiedAt => $composableBuilder(
    column: $table.verifiedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessageDbAccountsTableOrderingComposer get accountId {
    final $$MessageDbAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.messageDbAccounts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageDbAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.messageDbAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CoverageIntervalsTableAnnotationComposer
    extends Composer<_$MessageDatabase, $CoverageIntervalsTable> {
  $$CoverageIntervalsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get narrowKey =>
      $composableBuilder(column: $table.narrowKey, builder: (column) => column);

  GeneratedColumn<int> get lo =>
      $composableBuilder(column: $table.lo, builder: (column) => column);

  GeneratedColumn<int> get hi =>
      $composableBuilder(column: $table.hi, builder: (column) => column);

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<bool> get tracked =>
      $composableBuilder(column: $table.tracked, builder: (column) => column);

  GeneratedColumn<int> get verifiedAt => $composableBuilder(
    column: $table.verifiedAt,
    builder: (column) => column,
  );

  $$MessageDbAccountsTableAnnotationComposer get accountId {
    final $$MessageDbAccountsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.accountId,
          referencedTable: $db.messageDbAccounts,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$MessageDbAccountsTableAnnotationComposer(
                $db: $db,
                $table: $db.messageDbAccounts,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$CoverageIntervalsTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $CoverageIntervalsTable,
          StoredCoverageInterval,
          $$CoverageIntervalsTableFilterComposer,
          $$CoverageIntervalsTableOrderingComposer,
          $$CoverageIntervalsTableAnnotationComposer,
          $$CoverageIntervalsTableCreateCompanionBuilder,
          $$CoverageIntervalsTableUpdateCompanionBuilder,
          (StoredCoverageInterval, $$CoverageIntervalsTableReferences),
          StoredCoverageInterval,
          PrefetchHooks Function({bool accountId})
        > {
  $$CoverageIntervalsTableTableManager(
    _$MessageDatabase db,
    $CoverageIntervalsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CoverageIntervalsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CoverageIntervalsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CoverageIntervalsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<String> narrowKey = const Value.absent(),
                Value<int> lo = const Value.absent(),
                Value<int?> hi = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<bool> tracked = const Value.absent(),
                Value<int> verifiedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CoverageIntervalsCompanion(
                accountId: accountId,
                narrowKey: narrowKey,
                lo: lo,
                hi: hi,
                epoch: epoch,
                tracked: tracked,
                verifiedAt: verifiedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required String narrowKey,
                required int lo,
                Value<int?> hi = const Value.absent(),
                required int epoch,
                required bool tracked,
                required int verifiedAt,
                Value<int> rowid = const Value.absent(),
              }) => CoverageIntervalsCompanion.insert(
                accountId: accountId,
                narrowKey: narrowKey,
                lo: lo,
                hi: hi,
                epoch: epoch,
                tracked: tracked,
                verifiedAt: verifiedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CoverageIntervalsTable, StoredCoverageInterval>(
                    table,
                  ),
                  $$CoverageIntervalsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.accountId,
                        referencedTable: $$CoverageIntervalsTableReferences
                            ._accountIdTable(db),
                        referencedColumn: $$CoverageIntervalsTableReferences
                            ._accountIdTable(db)
                            .accountId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CoverageIntervalsTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $CoverageIntervalsTable,
      StoredCoverageInterval,
      $$CoverageIntervalsTableFilterComposer,
      $$CoverageIntervalsTableOrderingComposer,
      $$CoverageIntervalsTableAnnotationComposer,
      $$CoverageIntervalsTableCreateCompanionBuilder,
      $$CoverageIntervalsTableUpdateCompanionBuilder,
      (StoredCoverageInterval, $$CoverageIntervalsTableReferences),
      StoredCoverageInterval,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$MessageDbChannelsTableCreateCompanionBuilder =
    MessageDbChannelsCompanion Function({
      required int accountId,
      required int channelId,
      required bool historyPublicToSubscribers,
      Value<int> rowid,
    });
typedef $$MessageDbChannelsTableUpdateCompanionBuilder =
    MessageDbChannelsCompanion Function({
      Value<int> accountId,
      Value<int> channelId,
      Value<bool> historyPublicToSubscribers,
      Value<int> rowid,
    });

final class $$MessageDbChannelsTableReferences
    extends
        BaseReferences<
          _$MessageDatabase,
          $MessageDbChannelsTable,
          MessageDbChannel
        > {
  $$MessageDbChannelsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MessageDbAccountsTable _accountIdTable(_$MessageDatabase db) =>
      db.messageDbAccounts.createAlias(
        'message_db_channels__account_id__message_db_accounts__account_id',
      );

  $$MessageDbAccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$MessageDbAccountsTableTableManager(
      $_db,
      $_db.messageDbAccounts,
    ).filter((f) => f.accountId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MessageDbChannelsTableFilterComposer
    extends Composer<_$MessageDatabase, $MessageDbChannelsTable> {
  $$MessageDbChannelsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get historyPublicToSubscribers => $composableBuilder(
    column: $table.historyPublicToSubscribers,
    builder: (column) => ColumnFilters(column),
  );

  $$MessageDbAccountsTableFilterComposer get accountId {
    final $$MessageDbAccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.messageDbAccounts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageDbAccountsTableFilterComposer(
            $db: $db,
            $table: $db.messageDbAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageDbChannelsTableOrderingComposer
    extends Composer<_$MessageDatabase, $MessageDbChannelsTable> {
  $$MessageDbChannelsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get historyPublicToSubscribers => $composableBuilder(
    column: $table.historyPublicToSubscribers,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessageDbAccountsTableOrderingComposer get accountId {
    final $$MessageDbAccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.messageDbAccounts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageDbAccountsTableOrderingComposer(
            $db: $db,
            $table: $db.messageDbAccounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageDbChannelsTableAnnotationComposer
    extends Composer<_$MessageDatabase, $MessageDbChannelsTable> {
  $$MessageDbChannelsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<bool> get historyPublicToSubscribers => $composableBuilder(
    column: $table.historyPublicToSubscribers,
    builder: (column) => column,
  );

  $$MessageDbAccountsTableAnnotationComposer get accountId {
    final $$MessageDbAccountsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.accountId,
          referencedTable: $db.messageDbAccounts,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$MessageDbAccountsTableAnnotationComposer(
                $db: $db,
                $table: $db.messageDbAccounts,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$MessageDbChannelsTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $MessageDbChannelsTable,
          MessageDbChannel,
          $$MessageDbChannelsTableFilterComposer,
          $$MessageDbChannelsTableOrderingComposer,
          $$MessageDbChannelsTableAnnotationComposer,
          $$MessageDbChannelsTableCreateCompanionBuilder,
          $$MessageDbChannelsTableUpdateCompanionBuilder,
          (MessageDbChannel, $$MessageDbChannelsTableReferences),
          MessageDbChannel,
          PrefetchHooks Function({bool accountId})
        > {
  $$MessageDbChannelsTableTableManager(
    _$MessageDatabase db,
    $MessageDbChannelsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageDbChannelsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageDbChannelsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageDbChannelsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> channelId = const Value.absent(),
                Value<bool> historyPublicToSubscribers = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageDbChannelsCompanion(
                accountId: accountId,
                channelId: channelId,
                historyPublicToSubscribers: historyPublicToSubscribers,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int channelId,
                required bool historyPublicToSubscribers,
                Value<int> rowid = const Value.absent(),
              }) => MessageDbChannelsCompanion.insert(
                accountId: accountId,
                channelId: channelId,
                historyPublicToSubscribers: historyPublicToSubscribers,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessageDbChannelsTable, MessageDbChannel>(table),
                  $$MessageDbChannelsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.accountId,
                        referencedTable: $$MessageDbChannelsTableReferences
                            ._accountIdTable(db),
                        referencedColumn: $$MessageDbChannelsTableReferences
                            ._accountIdTable(db)
                            .accountId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MessageDbChannelsTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $MessageDbChannelsTable,
      MessageDbChannel,
      $$MessageDbChannelsTableFilterComposer,
      $$MessageDbChannelsTableOrderingComposer,
      $$MessageDbChannelsTableAnnotationComposer,
      $$MessageDbChannelsTableCreateCompanionBuilder,
      $$MessageDbChannelsTableUpdateCompanionBuilder,
      (MessageDbChannel, $$MessageDbChannelsTableReferences),
      MessageDbChannel,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$ServerSnapshotsTableCreateCompanionBuilder =
    ServerSnapshotsCompanion Function({
      Value<int> accountId,
      required String realmUrl,
      required int userId,
      required String queueId,
      required int lastEventId,
      required String appVersion,
      required int timestamp,
      Value<bool> eventLogTruncated,
    });
typedef $$ServerSnapshotsTableUpdateCompanionBuilder =
    ServerSnapshotsCompanion Function({
      Value<int> accountId,
      Value<String> realmUrl,
      Value<int> userId,
      Value<String> queueId,
      Value<int> lastEventId,
      Value<String> appVersion,
      Value<int> timestamp,
      Value<bool> eventLogTruncated,
    });

final class $$ServerSnapshotsTableReferences
    extends
        BaseReferences<
          _$MessageDatabase,
          $ServerSnapshotsTable,
          ServerSnapshot
        > {
  $$ServerSnapshotsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<
    $ServerSnapshotBlobsTable,
    List<ServerSnapshotBlob>
  >
  _serverSnapshotBlobsRefsTable(_$MessageDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.serverSnapshotBlobs,
        aliasName:
            'server_snapshots__account_id__server_snapshot_blobs__account_id',
      );

  $$ServerSnapshotBlobsTableProcessedTableManager get serverSnapshotBlobsRefs {
    final manager =
        $$ServerSnapshotBlobsTableTableManager(
          $_db,
          $_db.serverSnapshotBlobs,
        ).filter(
          (f) =>
              f.accountId.accountId.sqlEquals($_itemColumn<int>('account_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _serverSnapshotBlobsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ServerEventBatchesTable, List<ServerEventBatch>>
  _serverEventBatchesRefsTable(_$MessageDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.serverEventBatches,
        aliasName:
            'server_snapshots__account_id__server_event_batches__account_id',
      );

  $$ServerEventBatchesTableProcessedTableManager get serverEventBatchesRefs {
    final manager =
        $$ServerEventBatchesTableTableManager(
          $_db,
          $_db.serverEventBatches,
        ).filter(
          (f) =>
              f.accountId.accountId.sqlEquals($_itemColumn<int>('account_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _serverEventBatchesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ServerSnapshotsTableFilterComposer
    extends Composer<_$MessageDatabase, $ServerSnapshotsTable> {
  $$ServerSnapshotsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get realmUrl => $composableBuilder(
    column: $table.realmUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get queueId => $composableBuilder(
    column: $table.queueId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastEventId => $composableBuilder(
    column: $table.lastEventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get appVersion => $composableBuilder(
    column: $table.appVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get eventLogTruncated => $composableBuilder(
    column: $table.eventLogTruncated,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> serverSnapshotBlobsRefs(
    Expression<bool> Function($$ServerSnapshotBlobsTableFilterComposer f) f,
  ) {
    final $$ServerSnapshotBlobsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverSnapshotBlobs,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerSnapshotBlobsTableFilterComposer(
            $db: $db,
            $table: $db.serverSnapshotBlobs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> serverEventBatchesRefs(
    Expression<bool> Function($$ServerEventBatchesTableFilterComposer f) f,
  ) {
    final $$ServerEventBatchesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverEventBatches,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerEventBatchesTableFilterComposer(
            $db: $db,
            $table: $db.serverEventBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ServerSnapshotsTableOrderingComposer
    extends Composer<_$MessageDatabase, $ServerSnapshotsTable> {
  $$ServerSnapshotsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get realmUrl => $composableBuilder(
    column: $table.realmUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get queueId => $composableBuilder(
    column: $table.queueId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastEventId => $composableBuilder(
    column: $table.lastEventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get appVersion => $composableBuilder(
    column: $table.appVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get eventLogTruncated => $composableBuilder(
    column: $table.eventLogTruncated,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ServerSnapshotsTableAnnotationComposer
    extends Composer<_$MessageDatabase, $ServerSnapshotsTable> {
  $$ServerSnapshotsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get realmUrl =>
      $composableBuilder(column: $table.realmUrl, builder: (column) => column);

  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get queueId =>
      $composableBuilder(column: $table.queueId, builder: (column) => column);

  GeneratedColumn<int> get lastEventId => $composableBuilder(
    column: $table.lastEventId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get appVersion => $composableBuilder(
    column: $table.appVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<bool> get eventLogTruncated => $composableBuilder(
    column: $table.eventLogTruncated,
    builder: (column) => column,
  );

  Expression<T> serverSnapshotBlobsRefs<T extends Object>(
    Expression<T> Function($$ServerSnapshotBlobsTableAnnotationComposer a) f,
  ) {
    final $$ServerSnapshotBlobsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.accountId,
          referencedTable: $db.serverSnapshotBlobs,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ServerSnapshotBlobsTableAnnotationComposer(
                $db: $db,
                $table: $db.serverSnapshotBlobs,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> serverEventBatchesRefs<T extends Object>(
    Expression<T> Function($$ServerEventBatchesTableAnnotationComposer a) f,
  ) {
    final $$ServerEventBatchesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.accountId,
          referencedTable: $db.serverEventBatches,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ServerEventBatchesTableAnnotationComposer(
                $db: $db,
                $table: $db.serverEventBatches,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$ServerSnapshotsTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $ServerSnapshotsTable,
          ServerSnapshot,
          $$ServerSnapshotsTableFilterComposer,
          $$ServerSnapshotsTableOrderingComposer,
          $$ServerSnapshotsTableAnnotationComposer,
          $$ServerSnapshotsTableCreateCompanionBuilder,
          $$ServerSnapshotsTableUpdateCompanionBuilder,
          (ServerSnapshot, $$ServerSnapshotsTableReferences),
          ServerSnapshot,
          PrefetchHooks Function({
            bool serverSnapshotBlobsRefs,
            bool serverEventBatchesRefs,
          })
        > {
  $$ServerSnapshotsTableTableManager(
    _$MessageDatabase db,
    $ServerSnapshotsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerSnapshotsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerSnapshotsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerSnapshotsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<String> realmUrl = const Value.absent(),
                Value<int> userId = const Value.absent(),
                Value<String> queueId = const Value.absent(),
                Value<int> lastEventId = const Value.absent(),
                Value<String> appVersion = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
                Value<bool> eventLogTruncated = const Value.absent(),
              }) => ServerSnapshotsCompanion(
                accountId: accountId,
                realmUrl: realmUrl,
                userId: userId,
                queueId: queueId,
                lastEventId: lastEventId,
                appVersion: appVersion,
                timestamp: timestamp,
                eventLogTruncated: eventLogTruncated,
              ),
          createCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                required String realmUrl,
                required int userId,
                required String queueId,
                required int lastEventId,
                required String appVersion,
                required int timestamp,
                Value<bool> eventLogTruncated = const Value.absent(),
              }) => ServerSnapshotsCompanion.insert(
                accountId: accountId,
                realmUrl: realmUrl,
                userId: userId,
                queueId: queueId,
                lastEventId: lastEventId,
                appVersion: appVersion,
                timestamp: timestamp,
                eventLogTruncated: eventLogTruncated,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ServerSnapshotsTable, ServerSnapshot>(table),
                  $$ServerSnapshotsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                serverSnapshotBlobsRefs = false,
                serverEventBatchesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (serverSnapshotBlobsRefs) db.serverSnapshotBlobs,
                    if (serverEventBatchesRefs) db.serverEventBatches,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (serverSnapshotBlobsRefs)
                        await $_getPrefetchedData<
                          ServerSnapshot,
                          $ServerSnapshotsTable,
                          ServerSnapshotBlob
                        >(
                          currentTable: table,
                          referencedTable: $$ServerSnapshotsTableReferences
                              ._serverSnapshotBlobsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ServerSnapshotsTableReferences(
                                db,
                                table,
                                p0,
                              ).serverSnapshotBlobsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.accountId,
                              ),
                          typedResults: items,
                        ),
                      if (serverEventBatchesRefs)
                        await $_getPrefetchedData<
                          ServerSnapshot,
                          $ServerSnapshotsTable,
                          ServerEventBatch
                        >(
                          currentTable: table,
                          referencedTable: $$ServerSnapshotsTableReferences
                              ._serverEventBatchesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ServerSnapshotsTableReferences(
                                db,
                                table,
                                p0,
                              ).serverEventBatchesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.accountId,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ServerSnapshotsTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $ServerSnapshotsTable,
      ServerSnapshot,
      $$ServerSnapshotsTableFilterComposer,
      $$ServerSnapshotsTableOrderingComposer,
      $$ServerSnapshotsTableAnnotationComposer,
      $$ServerSnapshotsTableCreateCompanionBuilder,
      $$ServerSnapshotsTableUpdateCompanionBuilder,
      (ServerSnapshot, $$ServerSnapshotsTableReferences),
      ServerSnapshot,
      PrefetchHooks Function({
        bool serverSnapshotBlobsRefs,
        bool serverEventBatchesRefs,
      })
    >;
typedef $$ServerSnapshotBlobsTableCreateCompanionBuilder =
    ServerSnapshotBlobsCompanion Function({
      Value<int> accountId,
      required Uint8List data,
    });
typedef $$ServerSnapshotBlobsTableUpdateCompanionBuilder =
    ServerSnapshotBlobsCompanion Function({
      Value<int> accountId,
      Value<Uint8List> data,
    });

final class $$ServerSnapshotBlobsTableReferences
    extends
        BaseReferences<
          _$MessageDatabase,
          $ServerSnapshotBlobsTable,
          ServerSnapshotBlob
        > {
  $$ServerSnapshotBlobsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ServerSnapshotsTable _accountIdTable(_$MessageDatabase db) =>
      db.serverSnapshots.createAlias(
        'server_snapshot_blobs__account_id__server_snapshots__account_id',
      );

  $$ServerSnapshotsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$ServerSnapshotsTableTableManager(
      $_db,
      $_db.serverSnapshots,
    ).filter((f) => f.accountId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ServerSnapshotBlobsTableFilterComposer
    extends Composer<_$MessageDatabase, $ServerSnapshotBlobsTable> {
  $$ServerSnapshotBlobsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );

  $$ServerSnapshotsTableFilterComposer get accountId {
    final $$ServerSnapshotsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverSnapshots,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerSnapshotsTableFilterComposer(
            $db: $db,
            $table: $db.serverSnapshots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerSnapshotBlobsTableOrderingComposer
    extends Composer<_$MessageDatabase, $ServerSnapshotBlobsTable> {
  $$ServerSnapshotBlobsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );

  $$ServerSnapshotsTableOrderingComposer get accountId {
    final $$ServerSnapshotsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverSnapshots,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerSnapshotsTableOrderingComposer(
            $db: $db,
            $table: $db.serverSnapshots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerSnapshotBlobsTableAnnotationComposer
    extends Composer<_$MessageDatabase, $ServerSnapshotBlobsTable> {
  $$ServerSnapshotBlobsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);

  $$ServerSnapshotsTableAnnotationComposer get accountId {
    final $$ServerSnapshotsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverSnapshots,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerSnapshotsTableAnnotationComposer(
            $db: $db,
            $table: $db.serverSnapshots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerSnapshotBlobsTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $ServerSnapshotBlobsTable,
          ServerSnapshotBlob,
          $$ServerSnapshotBlobsTableFilterComposer,
          $$ServerSnapshotBlobsTableOrderingComposer,
          $$ServerSnapshotBlobsTableAnnotationComposer,
          $$ServerSnapshotBlobsTableCreateCompanionBuilder,
          $$ServerSnapshotBlobsTableUpdateCompanionBuilder,
          (ServerSnapshotBlob, $$ServerSnapshotBlobsTableReferences),
          ServerSnapshotBlob,
          PrefetchHooks Function({bool accountId})
        > {
  $$ServerSnapshotBlobsTableTableManager(
    _$MessageDatabase db,
    $ServerSnapshotBlobsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerSnapshotBlobsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerSnapshotBlobsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ServerSnapshotBlobsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback: ({
            Value<int> accountId = const Value.absent(),
            Value<Uint8List> data = const Value.absent(),
          }) => ServerSnapshotBlobsCompanion(accountId: accountId, data: data),
          createCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                required Uint8List data,
              }) => ServerSnapshotBlobsCompanion.insert(
                accountId: accountId,
                data: data,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ServerSnapshotBlobsTable, ServerSnapshotBlob>(
                    table,
                  ),
                  $$ServerSnapshotBlobsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.accountId,
                        referencedTable: $$ServerSnapshotBlobsTableReferences
                            ._accountIdTable(db),
                        referencedColumn: $$ServerSnapshotBlobsTableReferences
                            ._accountIdTable(db)
                            .accountId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ServerSnapshotBlobsTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $ServerSnapshotBlobsTable,
      ServerSnapshotBlob,
      $$ServerSnapshotBlobsTableFilterComposer,
      $$ServerSnapshotBlobsTableOrderingComposer,
      $$ServerSnapshotBlobsTableAnnotationComposer,
      $$ServerSnapshotBlobsTableCreateCompanionBuilder,
      $$ServerSnapshotBlobsTableUpdateCompanionBuilder,
      (ServerSnapshotBlob, $$ServerSnapshotBlobsTableReferences),
      ServerSnapshotBlob,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$ServerEventBatchesTableCreateCompanionBuilder =
    ServerEventBatchesCompanion Function({
      Value<int> id,
      required int accountId,
      required String queueId,
      required int lastEventId,
      required Uint8List data,
    });
typedef $$ServerEventBatchesTableUpdateCompanionBuilder =
    ServerEventBatchesCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<String> queueId,
      Value<int> lastEventId,
      Value<Uint8List> data,
    });

final class $$ServerEventBatchesTableReferences
    extends
        BaseReferences<
          _$MessageDatabase,
          $ServerEventBatchesTable,
          ServerEventBatch
        > {
  $$ServerEventBatchesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ServerSnapshotsTable _accountIdTable(_$MessageDatabase db) =>
      db.serverSnapshots.createAlias(
        'server_event_batches__account_id__server_snapshots__account_id',
      );

  $$ServerSnapshotsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$ServerSnapshotsTableTableManager(
      $_db,
      $_db.serverSnapshots,
    ).filter((f) => f.accountId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ServerEventBatchesTableFilterComposer
    extends Composer<_$MessageDatabase, $ServerEventBatchesTable> {
  $$ServerEventBatchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get queueId => $composableBuilder(
    column: $table.queueId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastEventId => $composableBuilder(
    column: $table.lastEventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );

  $$ServerSnapshotsTableFilterComposer get accountId {
    final $$ServerSnapshotsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverSnapshots,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerSnapshotsTableFilterComposer(
            $db: $db,
            $table: $db.serverSnapshots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerEventBatchesTableOrderingComposer
    extends Composer<_$MessageDatabase, $ServerEventBatchesTable> {
  $$ServerEventBatchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get queueId => $composableBuilder(
    column: $table.queueId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastEventId => $composableBuilder(
    column: $table.lastEventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );

  $$ServerSnapshotsTableOrderingComposer get accountId {
    final $$ServerSnapshotsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverSnapshots,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerSnapshotsTableOrderingComposer(
            $db: $db,
            $table: $db.serverSnapshots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerEventBatchesTableAnnotationComposer
    extends Composer<_$MessageDatabase, $ServerEventBatchesTable> {
  $$ServerEventBatchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get queueId =>
      $composableBuilder(column: $table.queueId, builder: (column) => column);

  GeneratedColumn<int> get lastEventId => $composableBuilder(
    column: $table.lastEventId,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);

  $$ServerSnapshotsTableAnnotationComposer get accountId {
    final $$ServerSnapshotsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.serverSnapshots,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerSnapshotsTableAnnotationComposer(
            $db: $db,
            $table: $db.serverSnapshots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerEventBatchesTableTableManager
    extends
        RootTableManager<
          _$MessageDatabase,
          $ServerEventBatchesTable,
          ServerEventBatch,
          $$ServerEventBatchesTableFilterComposer,
          $$ServerEventBatchesTableOrderingComposer,
          $$ServerEventBatchesTableAnnotationComposer,
          $$ServerEventBatchesTableCreateCompanionBuilder,
          $$ServerEventBatchesTableUpdateCompanionBuilder,
          (ServerEventBatch, $$ServerEventBatchesTableReferences),
          ServerEventBatch,
          PrefetchHooks Function({bool accountId})
        > {
  $$ServerEventBatchesTableTableManager(
    _$MessageDatabase db,
    $ServerEventBatchesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerEventBatchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerEventBatchesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerEventBatchesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> queueId = const Value.absent(),
                Value<int> lastEventId = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
              }) => ServerEventBatchesCompanion(
                id: id,
                accountId: accountId,
                queueId: queueId,
                lastEventId: lastEventId,
                data: data,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required String queueId,
                required int lastEventId,
                required Uint8List data,
              }) => ServerEventBatchesCompanion.insert(
                id: id,
                accountId: accountId,
                queueId: queueId,
                lastEventId: lastEventId,
                data: data,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ServerEventBatchesTable, ServerEventBatch>(
                    table,
                  ),
                  $$ServerEventBatchesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.accountId,
                        referencedTable: $$ServerEventBatchesTableReferences
                            ._accountIdTable(db),
                        referencedColumn: $$ServerEventBatchesTableReferences
                            ._accountIdTable(db)
                            .accountId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ServerEventBatchesTableProcessedTableManager =
    ProcessedTableManager<
      _$MessageDatabase,
      $ServerEventBatchesTable,
      ServerEventBatch,
      $$ServerEventBatchesTableFilterComposer,
      $$ServerEventBatchesTableOrderingComposer,
      $$ServerEventBatchesTableAnnotationComposer,
      $$ServerEventBatchesTableCreateCompanionBuilder,
      $$ServerEventBatchesTableUpdateCompanionBuilder,
      (ServerEventBatch, $$ServerEventBatchesTableReferences),
      ServerEventBatch,
      PrefetchHooks Function({bool accountId})
    >;

class $MessageDatabaseManager {
  final _$MessageDatabase _db;
  $MessageDatabaseManager(this._db);
  $$MessageDbAccountsTableTableManager get messageDbAccounts =>
      $$MessageDbAccountsTableTableManager(_db, _db.messageDbAccounts);
  $$StoredMessagesTableTableManager get storedMessages =>
      $$StoredMessagesTableTableManager(_db, _db.storedMessages);
  $$StoredMessageBodiesTableTableManager get storedMessageBodies =>
      $$StoredMessageBodiesTableTableManager(_db, _db.storedMessageBodies);
  $$StoredReactionsTableTableManager get storedReactions =>
      $$StoredReactionsTableTableManager(_db, _db.storedReactions);
  $$StoredSubmessagesTableTableManager get storedSubmessages =>
      $$StoredSubmessagesTableTableManager(_db, _db.storedSubmessages);
  $$CoverageIntervalsTableTableManager get coverageIntervals =>
      $$CoverageIntervalsTableTableManager(_db, _db.coverageIntervals);
  $$MessageDbChannelsTableTableManager get messageDbChannels =>
      $$MessageDbChannelsTableTableManager(_db, _db.messageDbChannels);
  $$ServerSnapshotsTableTableManager get serverSnapshots =>
      $$ServerSnapshotsTableTableManager(_db, _db.serverSnapshots);
  $$ServerSnapshotBlobsTableTableManager get serverSnapshotBlobs =>
      $$ServerSnapshotBlobsTableTableManager(_db, _db.serverSnapshotBlobs);
  $$ServerEventBatchesTableTableManager get serverEventBatches =>
      $$ServerEventBatchesTableTableManager(_db, _db.serverEventBatches);
}
