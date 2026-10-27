import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_tracker/invitation.dart';
import 'package:technician_tracker/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('technician_tracker/control');
  const events = MethodChannel('technician_tracker/state');
  final calls = <MethodCall>[];
  var rejectNextStart = false;
  final token = List.filled(64, 'a').join();
  final link =
      'https://${PublisherInvitation.siteHost}${PublisherInvitation.publisherPath}#invite=$token';
  setUp(() {
    calls.clear();
    rejectNextStart = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(control, (call) async {
          calls.add(call);
          if (call.method == 'startSharing' && rejectNextStart) {
            rejectNextStart = false;
            return <String, Object?>{
              'status': 'error',
              'sharing': false,
              'message':
                  'Allow location permission in Settings, then try again.',
            };
          }
          return switch (call.method) {
            'getState' => <String, Object?>{'status': 'idle', 'sharing': false},
            'validateInvitation' => <String, Object?>{
              'status': 'ready',
              'message': 'Invitation connected.',
              'sharing': false,
              'expiresAtMs': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch,
            },
            'startSharing' => <String, Object?>{
              'status': 'sharing',
              'message': 'Sharing GPS.',
              'sharing': true,
              'receivedAtMs': 1770000000000,
              'latitude': 18.6045,
              'longitude': 73.7344,
              'accuracy': 8.2,
            },
            'stopSharing' => <String, Object?>{
              'status': 'stopped',
              'message': 'Sharing stopped.',
              'sharing': false,
            },
            _ => throw MissingPluginException(),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(control, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, null);
  });

  testWidgets(
    'does not start GPS before explicit Start and invalid links never reach native code',
    (tester) async {
      await tester.pumpWidget(const TechnicianTrackerApp());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('startButton')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('invitationInput')),
        'https://evil.example/#invite=$token',
      );
      await tester.tap(find.byKey(const Key('connectButton')));
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['getState']);
      expect(
        find.text(
          'Paste the complete phone invitation link from LiveTracking.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'invalid replacement cannot start the previously connected session',
    (tester) async {
      await tester.pumpWidget(const TechnicianTrackerApp());
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('invitationInput')), link);
      await tester.tap(find.byKey(const Key('connectButton')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('startButton')))
            .onPressed,
        isNotNull,
      );
      await tester.enterText(
        find.byKey(const Key('invitationInput')),
        'invalid replacement',
      );
      await tester.tap(find.byKey(const Key('connectButton')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('startButton')))
            .onPressed,
        isNull,
      );
      expect(calls.where((c) => c.method == 'startSharing'), isEmpty);
      expect(
        calls.where((c) => c.method == 'validateInvitation'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'a denied start can be retried without pasting the invitation again',
    (tester) async {
      rejectNextStart = true;
      await tester.pumpWidget(const TechnicianTrackerApp());
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('invitationInput')), link);
      await tester.tap(find.byKey(const Key('connectButton')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('startButton')));
      await tester.tap(find.byKey(const Key('startButton')));
      await tester.pumpAndSettle();
      expect(find.text('Retry start'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('startButton')))
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(find.byKey(const Key('startButton')));
      await tester.tap(find.byKey(const Key('startButton')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'startSharing'), hasLength(2));
      expect(
        calls.where((c) => c.method == 'validateInvitation'),
        hasLength(1),
      );
      expect(find.text('Sharing your location'), findsOneWidget);
    },
  );

  testWidgets('connect, explicit start, upload receipt and stop lifecycle', (
    tester,
  ) async {
    await tester.pumpWidget(const TechnicianTrackerApp());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invitationInput')), link);
    await tester.tap(find.byKey(const Key('connectButton')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'startSharing'), isEmpty);
    expect(find.text(link), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('startButton')));
    await tester.tap(find.byKey(const Key('startButton')));
    await tester.pumpAndSettle();
    expect(calls.firstWhere((c) => c.method == 'startSharing').arguments, {
      'token': token,
    });
    expect(find.text('Sharing your location'), findsOneWidget);
    expect(find.text('18.604500, 73.734400'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('stopButton')));
    await tester.tap(find.byKey(const Key('stopButton')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'stopSharing'), hasLength(1));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('startButton')))
          .onPressed,
      isNull,
    );
    expect(find.text('Location sharing stopped'), findsOneWidget);
  });
}
