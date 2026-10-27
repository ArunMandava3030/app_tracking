import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'invitation.dart';
import 'tracking_bridge.dart';

void main() => runApp(const TechnicianTrackerApp());

class TechnicianTrackerApp extends StatelessWidget {
  const TechnicianTrackerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Technician Tracker',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1458A8)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF5F7FB),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: const TrackingScreen(),
  );
}

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});
  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen>
    with WidgetsBindingObserver {
  final _link = TextEditingController();
  final _bridge = TrackingBridge();
  StreamSubscription<TrackingState>? _subscription;
  TrackingState _state = const TrackingState();
  String? _token;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _bridge.states.listen(
      _receive,
      onError: (Object _) {
        if (mounted)
          setState(() => _error = 'Unable to read the tracking status.');
      },
    );
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  void _receive(TrackingState state) {
    if (!mounted) return;
    setState(() {
      _state = state;
      if (state.isTerminal) _token = null;
    });
  }

  Future<void> _refresh() async {
    try {
      _receive(await _bridge.current());
    } on PlatformException {
      if (mounted)
        setState(() => _error = 'Unable to read the tracking status.');
    } on MissingPluginException {
      if (mounted) {
        setState(() => _error = 'Run this app on an Android phone or iPhone.');
      }
    }
  }

  Future<void> _run(Future<TrackingState> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _receive(await action());
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on PlatformException {
      if (mounted)
        setState(
          () => _error =
              'Unable to complete this action. Check location permissions and your connection, then try again.',
        );
    } on MissingPluginException {
      if (mounted)
        setState(() => _error = 'Run this app on an Android phone or iPhone.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
    // A failed replacement must not leave Start enabled for the old invitation.
    _token = null;
    final invitation = PublisherInvitation.parse(_link.text);
    final state = await _bridge.validate(invitation.token);
    _token = state.canStart ? invitation.token : null;
    if (state.canStart) {
      _link.clear();
      if (mounted) FocusScope.of(context).unfocus();
    }
    return state;
  });

  Future<void> _start() async {
    final token = _token;
    if (token != null) await _run(() => _bridge.start(token));
  }

  Future<void> _stop() => _run(() async {
    _token = null;
    return _bridge.stop();
  });

  String _time(int? milliseconds) {
    if (milliseconds == null) return 'Not yet';
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(milliseconds)),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _state.sharing || _state.isStarting;
    final theme = Theme.of(context);
    final coordinates = _state.latitude == null || _state.longitude == null
        ? 'Waiting for a GPS fix'
        : '${_state.latitude!.toStringAsFixed(6)}, ${_state.longitude!.toStringAsFixed(6)}';
    final title = switch (_state.status) {
      'ready' => 'Invitation connected',
      'starting' => _state.sharing ? 'Starting GPS' : 'Connecting session',
      'sharing' => 'Sharing your location',
      'retrying' => 'Waiting to send an update',
      'stopped' => 'Location sharing stopped',
      'expired' => 'Invitation ended',
      'error' => 'Action needed',
      _ => 'Ready when you are',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Technician Tracker')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Share your journey',
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your agent and customer can follow your location during this session.',
                ),
                const SizedBox(height: 24),
                if (!active) ...[
                  TextField(
                    key: const Key('invitationInput'),
                    controller: _link,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 4,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Phone invitation link',
                      hintText: 'Paste the link your agent sent',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('connectButton'),
                    onPressed: _busy ? null : _connect,
                    icon: const Icon(Icons.link),
                    label: const Text('Connect invitation'),
                  ),
                  const SizedBox(height: 16),
                ],
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          active
                              ? Icons.location_on
                              : Icons.location_on_outlined,
                          color: theme.colorScheme.primary,
                          size: 32,
                        ),
                        const SizedBox(height: 12),
                        Text(title, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Semantics(
                          liveRegion: true,
                          child: Text(_state.message),
                        ),
                        if (_state.expiresAtMs != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Session expires at ${_time(_state.expiresAtMs)}',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                if (active)
                  FilledButton.tonalIcon(
                    key: const Key('stopButton'),
                    onPressed: _busy ? null : _stop,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop sharing'),
                  )
                else
                  FilledButton.icon(
                    key: const Key('startButton'),
                    onPressed:
                        !_busy &&
                            (_state.canStart || _state.status == 'error') &&
                            _token != null
                        ? _start
                        : null,
                    icon: const Icon(Icons.near_me_outlined),
                    label: Text(
                      _state.status == 'error' && _token != null
                          ? 'Retry start'
                          : 'Start sharing',
                    ),
                  ),
                const SizedBox(height: 20),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.cloud_done_outlined),
                        title: const Text('Last saved to Salesforce'),
                        subtitle: Text(_time(_state.receivedAtMs)),
                      ),
                      ListTile(
                        leading: const Icon(Icons.my_location),
                        title: const Text('Latest phone location'),
                        subtitle: Text(coordinates),
                      ),
                      if (_state.accuracy != null)
                        ListTile(
                          leading: const Icon(Icons.gps_fixed),
                          title: const Text('GPS accuracy'),
                          subtitle: Text(
                            'About ${_state.accuracy!.round()} metres',
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Location sharing starts only after you tap Start sharing and grant permission. '
                  'It can continue with the screen locked. Keep the app running; force-stopping it ends tracking.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Stop sharing stops GPS immediately and revokes this phone invitation when online. '
                  'Ask your agent for a new invitation to start again.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
