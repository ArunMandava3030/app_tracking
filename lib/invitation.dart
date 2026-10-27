/// Only this organization's publisher invitation is accepted. The pasted URL
/// never controls the upload destination and is never opened in a WebView.
class PublisherInvitation {
  static const siteHost = 'ddm00000pb3etuay-dev-ed.develop.my.site.com';
  static const publisherPath = '/LiveTracking/apex/TechnicianGpsInvite';
  static const apiUrl =
      'https://$siteHost/LiveTracking/services/apexrest/technician-tracking/v1/publisher';

  final String token;
  const PublisherInvitation._(this.token);

  factory PublisherInvitation.parse(String input) {
    const message =
        'Paste the complete phone invitation link from LiveTracking.';
    final value = input.trim();
    if (value.length > 1024 || value.contains(RegExp(r'\s'))) {
      throw const FormatException(message);
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != siteHost ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.path != publisherPath ||
        uri.hasQuery ||
        !RegExp(r'^invite=[a-fA-F0-9]{64}$').hasMatch(uri.fragment)) {
      throw const FormatException(message);
    }
    return PublisherInvitation._(uri.fragment.substring(7).toLowerCase());
  }
}
