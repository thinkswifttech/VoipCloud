import '../../calls/domain/call_direction.dart';
import 'call_history_item.dart';

const _callBoundaryTolerance = Duration(seconds: 3);
const _zeroLengthStartTolerance = Duration(seconds: 10);

/// Returns true when two records are legs or observations of one logical call.
///
/// Queue and B2BUA routing can create multiple SIP call IDs. Comparing their
/// overlapping time windows is safer than requiring identical IDs or start
/// timestamps, while still keeping sequential calls from the same party apart.
bool isSameLogicalCall(CallHistoryItem left, CallHistoryItem right) {
  if (left.id == right.id) return true;
  if (_isOutgoing(left) != _isOutgoing(right)) return false;
  if (_normalizedParty(left.remoteNumber) !=
      _normalizedParty(right.remoteNumber)) {
    return false;
  }

  final leftEnd = _validEnd(left);
  final rightEnd = _validEnd(right);
  final overlaps =
      !left.startedAt.isAfter(rightEnd.add(_callBoundaryTolerance)) &&
      !right.startedAt.isAfter(leftEnd.add(_callBoundaryTolerance));
  if (overlaps) return true;

  return left.startedAt.difference(right.startedAt).abs() <=
      _zeroLengthStartTolerance;
}

/// Combines independent observations without allowing weak `missed` evidence
/// to overwrite an answered or answered-elsewhere result.
CallHistoryItem mergeLogicalCall(
  CallHistoryItem primary,
  CallHistoryItem secondary, {
  bool preservePrimaryId = true,
}) {
  final preferred = _preferredEvidence(primary, secondary);
  final displayName = _preferredDisplayName(
    primary.remoteDisplayName,
    secondary.remoteDisplayName,
  );
  final earliestStart = primary.startedAt.isBefore(secondary.startedAt)
      ? primary.startedAt
      : secondary.startedAt;
  final latestEnd = _latest(primary.endedAt, secondary.endedAt);
  return CallHistoryItem(
    id: preservePrimaryId
        ? primary.id
        : _preferredIdentity(primary, secondary).id,
    remoteNumber: _preferredRemoteNumber(primary, secondary),
    remoteDisplayName: displayName,
    direction: preferred.direction,
    status: preferred.status,
    disposition: preferred.effectiveDisposition,
    startedAt: earliestStart,
    endedAt: latestEnd,
  );
}

CallHistoryItem _preferredIdentity(
  CallHistoryItem left,
  CallHistoryItem right,
) {
  final leftScore = _displayNameScore(left.remoteDisplayName);
  final rightScore = _displayNameScore(right.remoteDisplayName);
  if (leftScore != rightScore) return rightScore > leftScore ? right : left;
  return _latestEvidence(left, right);
}

List<CallHistoryItem> coalesceLogicalCalls(Iterable<CallHistoryItem> items) {
  final result = <CallHistoryItem>[];
  final sorted = items.toList()
    ..sort((left, right) => left.startedAt.compareTo(right.startedAt));
  for (final item in sorted) {
    final match = result.indexWhere(
      (candidate) => isSameLogicalCall(candidate, item),
    );
    if (match < 0) {
      result.add(item);
      continue;
    }
    result[match] = mergeLogicalCall(
      result[match],
      item,
      preservePrimaryId: false,
    );
  }
  result.sort((left, right) => right.startedAt.compareTo(left.startedAt));
  return result;
}

CallHistoryItem _preferredEvidence(
  CallHistoryItem left,
  CallHistoryItem right,
) {
  if (_isOutgoing(left)) {
    final leftCompleted = left.status.name == 'ended';
    final rightCompleted = right.status.name == 'ended';
    if (leftCompleted != rightCompleted) return rightCompleted ? right : left;
    return _latestEvidence(left, right);
  }
  final leftRank = _dispositionRank(left.effectiveDisposition);
  final rightRank = _dispositionRank(right.effectiveDisposition);
  if (leftRank != rightRank) return rightRank > leftRank ? right : left;
  return _latestEvidence(left, right);
}

CallHistoryItem _latestEvidence(CallHistoryItem left, CallHistoryItem right) {
  final leftAt = left.endedAt ?? left.startedAt;
  final rightAt = right.endedAt ?? right.startedAt;
  return rightAt.isAfter(leftAt) ? right : left;
}

int _dispositionRank(CallHistoryDisposition disposition) =>
    switch (disposition) {
      CallHistoryDisposition.answered => 4,
      CallHistoryDisposition.answeredElsewhere => 3,
      CallHistoryDisposition.declined => 2,
      CallHistoryDisposition.missed => 1,
      CallHistoryDisposition.outgoing => 0,
    };

String? _preferredDisplayName(String? left, String? right) {
  final leftScore = _displayNameScore(left);
  final rightScore = _displayNameScore(right);
  return rightScore > leftScore ? right : left;
}

int _displayNameScore(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 0;
  return 1 + (text.contains(':') ? 1000 : 0) + text.length;
}

String _preferredRemoteNumber(CallHistoryItem left, CallHistoryItem right) {
  final leftValue = left.remoteNumber.trim();
  final rightValue = right.remoteNumber.trim();
  if (leftValue.contains(':') != rightValue.contains(':')) {
    return leftValue.contains(':') ? left.remoteNumber : right.remoteNumber;
  }
  return leftValue.length >= rightValue.length
      ? left.remoteNumber
      : right.remoteNumber;
}

bool _isOutgoing(CallHistoryItem item) =>
    item.direction == CallDirection.outgoing;

DateTime _validEnd(CallHistoryItem item) {
  final endedAt = item.endedAt;
  if (endedAt == null || endedAt.isBefore(item.startedAt)) {
    return item.startedAt;
  }
  return endedAt;
}

DateTime? _latest(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left.isAfter(right) ? left : right;
}

String _normalizedParty(String value) {
  final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
  return digits.isEmpty ? value.trim().toLowerCase() : digits;
}
