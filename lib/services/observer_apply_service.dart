import '../helpers/config_profile_writes.dart';
import 'observer_config_service.dart';

/// Result of applying one write (or one broker slot). [label] is safe to show,
/// it names the key/slot, never a value, so secrets never leak into UI or logs.
class ApplyItemResult {
  const ApplyItemResult(this.label, this.ok, [this.error]);
  final String label;
  final bool ok;
  final String? error;
}

class ObserverApplyResult {
  const ObserverApplyResult(this.items);
  final List<ApplyItemResult> items;

  bool get allOk => items.every((i) => i.ok);
  List<ApplyItemResult> get failures => items.where((i) => !i.ok).toList();
}

/// Applies a [ProfileWrites] plan to the connected observer (#405).
///
/// Globals go through [ObserverConfigService.setFlat]; each broker through
/// [ObserverConfigService.saveBroker], which already disables-first, writes
/// field-at-a-time, writes `enabled` LAST, and stops at the first failure so a
/// partial save never leaves a slot live-but-corrupt (#80). We read the slot's
/// current `enabled` first so a profile that omits it preserves device state.
class ObserverApplyService {
  ObserverApplyService(this._svc);
  final ObserverConfigService _svc;

  Future<ObserverApplyResult> apply(ProfileWrites writes) async {
    final items = <ApplyItemResult>[];

    for (final f in writes.flats) {
      final ok = await _svc.setFlat(f.key, f.value);
      items.add(ApplyItemResult(f.key, ok, ok ? null : _svc.lastError));
    }

    for (final b in writes.brokers) {
      // Import NEVER touches enabled state (#470, owner directive): a config
      // import carries no enabled/disabled, and the firmware already force-
      // disables a slot on any field write (#53). We do not re-enable — the slot
      // is left DISABLED and the operator re-enables intentionally. Prior enabled
      // state is not carried over.
      final res = await _svc.saveBroker(
        b.slot,
        fields: b.fields,
        enable: false,
        wasLive: false,
      );
      items.add(
        res.ok
            ? ApplyItemResult('broker ${b.slot}', true)
            : ApplyItemResult(
                'broker ${b.slot}',
                false,
                'field "${res.failedField}" failed, slot left disabled',
              ),
      );
    }

    return ObserverApplyResult(items);
  }
}
