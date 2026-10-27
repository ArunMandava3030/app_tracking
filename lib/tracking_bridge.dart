import 'package:flutter/services.dart';

class TrackingState {
  final String status;
  final String message;
  final bool sharing;
  final int? expiresAtMs;
  final int? receivedAtMs;
  final int? capturedAtMs;
  final double? latitude;
  final double? longitude;
  final double? accuracy;

  const TrackingState({
    this.status = 'idle',
    this.message = 'Connect your invitation to get started.',
    this.sharing = false,
    this.expiresAtMs,
    this.receivedAtMs,
    this.capturedAtMs,
    this.latitude,
    this.longitude,
    this.accuracy,
  });

  factory TrackingState.fromMap(Map<Object?, Object?> map) => TrackingState(
    status: map['status'] as String? ?? 'idle',
    message: map['message'] as String? ?? '',
    sharing: map['sharing'] == true,
    expiresAtMs: (map['expiresAtMs'] as num?)?.toInt(),
    receivedAtMs: (map['receivedAtMs'] as num?)?.toInt(),
    capturedAtMs: (map['capturedAtMs'] as num?)?.toInt(),
    latitude: (map['latitude'] as num?)?.toDouble(),
    longitude: (map['longitude'] as num?)?.toDouble(),
    accuracy: (map['accuracy'] as num?)?.toDouble(),
  );

  bool get isStarting => status == 'starting';
  bool get canStart => status == 'ready' && !sharing;
  bool get isTerminal => status == 'stopped' || status == 'expired';
}

/// Location collection and HTTP upload run in native code, independently of
/// the Dart UI. No Dart timer is used for background GPS.
class TrackingBridge {
  static const _control = MethodChannel('technician_tracker/control');
  static const _events = EventChannel('technician_tracker/state');

  Stream<TrackingState> get states => _events.receiveBroadcastStream().map(
    (dynamic event) =>
        TrackingState.fromMap(Map<Object?, Object?>.from(event as Map)),
  );

  Future<TrackingState> _call(String method, [String? token]) async {
    final result = await _control.invokeMapMethod<Object?, Object?>(
      method,
      token == null ? null : <String, Object?>{'token': token},
    );
    return TrackingState.fromMap(result ?? <Object?, Object?>{});
  }

  Future<TrackingState> current() => _call('getState');
  Future<TrackingState> validate(String token) =>
      _call('validateInvitation', token);
  Future<TrackingState> start(String token) => _call('startSharing', token);
  Future<TrackingState> stop() => _call('stopSharing');
}
