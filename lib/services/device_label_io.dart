import 'dart:io';

/// Native best-effort label: `Platform (hostname)`, e.g. "Linux
/// (chef-laptop)". Falls back to just the platform name if the hostname is
/// empty, and to null if reading either throws (a locked-down sandbox, for
/// example), a label-derivation failure must never break enrollment.
String? guessDeviceLabel() {
  try {
    final platform = _platformName(Platform.operatingSystem);
    final host = Platform.localHostname.trim();
    return host.isEmpty ? platform : '$platform ($host)';
  } catch (_) {
    return null;
  }
}

String _platformName(String os) {
  switch (os) {
    case 'macos':
      return 'Mac';
    case 'linux':
      return 'Linux';
    case 'windows':
      return 'Windows';
    case 'android':
      return 'Android';
    case 'ios':
      return 'iPhone';
    default:
      return os;
  }
}
