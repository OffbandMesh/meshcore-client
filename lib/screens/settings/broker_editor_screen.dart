import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/observer_config.dart';
import '../../services/observer_config_service.dart';

/// Edit one MQTT broker slot (#80). Staged-save: controls edit LOCAL state and
/// nothing reaches the device until Save, which writes only the CHANGED fields
/// field-at-a-time with `enabled` written LAST (the activation guard) via
/// [ObserverConfigService.saveBroker]. A partial save leaves the slot disabled,
/// never live-corrupt. Refresh re-reads the single slot; the back button guards
/// unsaved edits.
class BrokerEditorScreen extends StatefulWidget {
  const BrokerEditorScreen({super.key, required this.broker});

  final BrokerConfig broker;

  @override
  State<BrokerEditorScreen> createState() => _BrokerEditorScreenState();
}

class _BrokerEditorScreenState extends State<BrokerEditorScreen> {
  late final TextEditingController _url;
  late final TextEditingController _port;
  late final TextEditingController _username;
  final _password = TextEditingController();
  late final TextEditingController _topicPrefix;
  late final TextEditingController _iataOverride;
  late final TextEditingController _jwtAudience;
  late final TextEditingController _jwtRefresh;
  late final TextEditingController _jwtOwner;
  late final TextEditingController _jwtEmail;
  late final TextEditingController _caCert;
  late BrokerTransport _transport;
  late BrokerAuthType _authType;
  late bool _enabled;

  /// The device snapshot the form is diffed against. Updated by Refresh so a
  /// re-read becomes the new "unchanged" baseline.
  late BrokerConfig _baseline;
  bool _busy = false;

  String get _portText => _baseline.isPopulated ? '${_baseline.port}' : '';
  String get _jwtRefreshText =>
      _baseline.jwtRefresh == 0 ? '' : '${_baseline.jwtRefresh}';

  @override
  void initState() {
    super.initState();
    _baseline = widget.broker;
    _url = TextEditingController(text: _baseline.url);
    _port = TextEditingController(text: _portText);
    _username = TextEditingController(text: _baseline.username);
    _topicPrefix = TextEditingController(text: _baseline.topicPrefix);
    _iataOverride = TextEditingController(text: _baseline.iataOverride);
    _jwtAudience = TextEditingController(text: _baseline.jwtAudience);
    _jwtRefresh = TextEditingController(text: _jwtRefreshText);
    _jwtOwner = TextEditingController(text: _baseline.jwtOwner);
    _jwtEmail = TextEditingController(text: _baseline.jwtEmail);
    _caCert = TextEditingController(text: _baseline.caCert);
    _transport = _baseline.transport;
    _authType = _baseline.authType;
    _enabled = _baseline.enabled;
  }

  @override
  void dispose() {
    for (final c in [
      _url,
      _port,
      _username,
      _password,
      _topicPrefix,
      _iataOverride,
      _jwtAudience,
      _jwtRefresh,
      _jwtOwner,
      _jwtEmail,
      _caCert,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Fields whose local value differs from [_baseline]. Password is write-only:
  /// it is sent ONLY when the user typed a new one (the stored value is never
  /// read back, so a blank field keeps it).
  Map<String, String> _changedFields() {
    final f = <String, String>{};
    void diff(String key, String now, String was) {
      if (now != was) f[key] = now;
    }

    diff('url', _url.text, _baseline.url);
    diff('port', _port.text, _portText);
    if (_transport != _baseline.transport) f['transport'] = _transport.wire;
    if (_authType != _baseline.authType) f['auth_type'] = _authType.wire;
    diff('username', _username.text, _baseline.username);
    diff('topic_prefix', _topicPrefix.text, _baseline.topicPrefix);
    diff('iata_override', _iataOverride.text, _baseline.iataOverride);
    diff('jwt_audience', _jwtAudience.text, _baseline.jwtAudience);
    diff('jwt_refresh', _jwtRefresh.text, _jwtRefreshText);
    diff('jwt_owner', _jwtOwner.text, _baseline.jwtOwner);
    diff('jwt_email', _jwtEmail.text, _baseline.jwtEmail);
    diff('ca_cert', _caCert.text, _baseline.caCert);
    if (_password.text.isNotEmpty) f['password'] = _password.text;
    return f;
  }

  bool get _dirty =>
      _changedFields().isNotEmpty || _enabled != _baseline.enabled;

  /// Pre-enable validation, shared with the list's quick Enable via
  /// [BrokerConfig.enableError]. Only structural fields (URL, port) gate a save
  /// — the firmware enforces the rest via its own defaults.
  String? _validate() => BrokerConfig(
    slot: _baseline.slot,
    url: _url.text.trim(),
    port: int.tryParse(_port.text.trim()) ?? -1,
  ).enableError;

  void _snack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _save() async {
    // Validation only gates ENABLING — disabling a slot with blank/partial
    // fields is fine; it won't be active.
    if (_enabled) {
      final err = _validate();
      if (err != null) {
        _snack(err, isError: true);
        return;
      }
    }
    final intended = _enabled;
    final svc = context.read<ObserverConfigService>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    setState(() => _busy = true);
    final result = await svc.saveBroker(
      _baseline.slot,
      fields: _changedFields(),
      enable: intended,
      wasLive: _baseline.enabled,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Save failed at "${result.failedField ?? 'a field'}" — the slot '
            'was left disabled. Re-read and retry.',
          ),
          backgroundColor: errorColor,
        ),
      );
      return;
    }
    // The writes were ACKed — but a firmware build can ACK without applying the
    // enabled state (meshcore-firmware#179). Settle, re-read, and only claim
    // success if the device actually matches what we asked for.
    await Future.delayed(ObserverConfigService.applySettleDelay);
    if (!mounted) return;
    final fresh = await svc.getBroker(_baseline.slot);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (BrokerConfig.classifyApply(
      intendedEnabled: intended,
      actualEnabled: fresh?.enabled,
    )) {
      case BrokerApplyOutcome.applied:
        messenger.showSnackBar(
          SnackBar(content: Text('Broker ${_baseline.slot} saved')),
        );
        navigator.pop(true);
      case BrokerApplyOutcome.notApplied:
        // Stay on the editor, re-seed to the device's true state, and warn — the
        // fields were written but the device didn't honor the enable/disable.
        if (fresh != null) _seedFrom(fresh);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Saved, but the device did not ${intended ? 'enable' : 'disable'} '
              'broker ${_baseline.slot} — possible firmware issue',
            ),
            backgroundColor: errorColor,
          ),
        );
      case BrokerApplyOutcome.unverified:
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Broker ${_baseline.slot} saved — could not confirm enabled '
              'state (device may be rebooting)',
            ),
          ),
        );
        navigator.pop(true);
    }
  }

  Future<void> _refresh() async {
    final svc = context.read<ObserverConfigService>();
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    if (_dirty && !await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final fresh = await svc.getBroker(_baseline.slot);
    if (!mounted) return;
    setState(() => _busy = false);
    if (fresh == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not read broker ${_baseline.slot}'),
          backgroundColor: errorColor,
        ),
      );
      return;
    }
    _seedFrom(fresh);
  }

  void _seedFrom(BrokerConfig b) {
    setState(() {
      _baseline = b;
      _url.text = b.url;
      _port.text = _portText;
      _username.text = b.username;
      _topicPrefix.text = b.topicPrefix;
      _iataOverride.text = b.iataOverride;
      _jwtAudience.text = b.jwtAudience;
      _jwtRefresh.text = _jwtRefreshText;
      _jwtOwner.text = b.jwtOwner;
      _jwtEmail.text = b.jwtEmail;
      _caCert.text = b.caCert;
      _transport = b.transport;
      _authType = b.authType;
      _enabled = b.enabled;
      _password.clear();
    });
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this broker have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Text('Broker ${_baseline.slot}'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _busy ? null : _refresh,
            ),
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'Save',
              onPressed: _busy ? null : _save,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              subtitle: const Text('Written last on save (activation guard)'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            const Divider(height: 24),
            _field('broker_url', _url, 'URL'),
            _field('broker_port', _port, 'Port', number: true),
            const SizedBox(height: 12),
            _sectionLabel('Transport'),
            SegmentedButton<BrokerTransport>(
              segments: const [
                ButtonSegment(value: BrokerTransport.tcp, label: Text('tcp')),
                ButtonSegment(value: BrokerTransport.tls, label: Text('tls')),
                ButtonSegment(value: BrokerTransport.wss, label: Text('wss')),
              ],
              selected: {_transport},
              onSelectionChanged: (s) => setState(() => _transport = s.first),
            ),
            const SizedBox(height: 16),
            _sectionLabel('Auth'),
            SegmentedButton<BrokerAuthType>(
              segments: const [
                ButtonSegment(value: BrokerAuthType.none, label: Text('none')),
                ButtonSegment(
                  value: BrokerAuthType.basic,
                  label: Text('basic'),
                ),
                ButtonSegment(value: BrokerAuthType.jwt, label: Text('jwt')),
              ],
              selected: {_authType},
              onSelectionChanged: (s) => setState(() => _authType = s.first),
            ),
            if (_authType == BrokerAuthType.basic) ...[
              const SizedBox(height: 12),
              _field('broker_username', _username, 'Username'),
              _secretField(),
            ],
            if (_authType == BrokerAuthType.jwt) ...[
              const SizedBox(height: 12),
              _field('broker_jwt_audience', _jwtAudience, 'JWT audience'),
              _field('broker_jwt_owner', _jwtOwner, 'JWT owner'),
              _field('broker_jwt_email', _jwtEmail, 'JWT email'),
              _field(
                'broker_jwt_refresh',
                _jwtRefresh,
                'JWT refresh (sec)',
                number: true,
              ),
            ],
            const Divider(height: 24),
            _field('broker_topic_prefix', _topicPrefix, 'Topic prefix'),
            _field('broker_iata_override', _iataOverride, 'IATA override'),
            if (_transport != BrokerTransport.tcp)
              _field(
                'broker_ca_cert',
                _caCert,
                'CA certificate (PEM)',
                lines: 3,
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(t, style: Theme.of(context).textTheme.labelLarge),
  );

  Widget _field(
    String key,
    TextEditingController c,
    String label, {
    bool number = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key(key),
      controller: c,
      maxLines: lines,
      keyboardType: number ? TextInputType.number : null,
      inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _secretField() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: const Key('broker_password'),
      controller: _password,
      obscureText: true,
      decoration: InputDecoration(
        labelText: _baseline.passwordSet
            ? 'Password (set — leave blank to keep)'
            : 'Password',
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
