import 'package:flutter_test/flutter_test.dart';
import 'package:technician_tracker/invitation.dart';

void main() {
  final token = List.filled(64, 'a').join();
  final link =
      'https://${PublisherInvitation.siteHost}${PublisherInvitation.publisherPath}#invite=$token';
  test(
    'accepts the exact existing phone invitation and trims pasted whitespace',
    () {
      expect(PublisherInvitation.parse(' $link\n').token, token);
      expect(
        PublisherInvitation.parse(
          link.replaceFirst(token, token.toUpperCase()),
        ).token,
        token,
      );
    },
  );
  test('rejects untrusted origins, customer tokens and ambiguous URLs', () {
    for (final bad in [
      link.replaceFirst('https:', 'http:'),
      link.replaceFirst(PublisherInvitation.siteHost, 'evil.example'),
      link.replaceFirst(
        PublisherInvitation.siteHost,
        '${PublisherInvitation.siteHost}.evil.example',
      ),
      link.replaceFirst('https://', 'https://user:pass@'),
      link.replaceFirst('/LiveTracking/', ':444/LiveTracking/'),
      link.replaceFirst('#invite=', '?redirect=evil#invite='),
      link.replaceFirst('#invite=', '#customer='),
      '$link&invite=$token',
      '$link&customer=$token',
      '$link ',
      link.replaceFirst('apex/', 's/'),
      link.replaceFirst(token, token.substring(1)),
      link.replaceFirst(token, '${token}a'),
      link.replaceFirst(token, token.replaceFirst('a', 'g')),
      token,
      '',
      'https://example.com/#invite=$token',
    ].where((v) => v != '$link ')) {
      expect(
        () => PublisherInvitation.parse(bad),
        throwsFormatException,
        reason: bad.replaceAll(token, '[redacted]'),
      );
    }
  });
}
