/// Server transaction sequence IDs exceed JavaScript's exact numeric range.
/// Compare them as integers, preserving the server order within one second.
int compareTransactionsNewestFirst(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  BigInt value(Map<String, dynamic> item, String key) =>
      BigInt.tryParse('${item[key]}') ?? BigInt.zero;
  final time = value(b, 'time').compareTo(value(a, 'time'));
  if (time != 0) return time;
  final sequence = value(
    b,
    'timeSequenceId',
  ).compareTo(value(a, 'timeSequenceId'));
  if (sequence != 0) return sequence;
  final id = value(b, 'id').compareTo(value(a, 'id'));
  return id != 0 ? id : '${b['id']}'.compareTo('${a['id']}');
}
