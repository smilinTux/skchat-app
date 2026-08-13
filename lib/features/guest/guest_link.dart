/// Parsing for the guest-invite deep link `/g/<token>` and `/g/<token>&k=<k>`.
///
/// The server (skchat `pq_invites.build_join_url`) deliberately keeps every
/// secret after the `#`, so when signed invites are on it mints
/// `/app/#/g/<token>&k=<fragment-secret>`. That `&` is NOT a query separator
/// here: it sits inside the fragment route, so GoRouter captures the whole
/// `<token>&k=<k>` string as the `:token` path parameter.
///
/// Passing that straight through as the invite token appends `&k=...` to the
/// JWT, so every preview and join fails signature verification. The server
/// answers with its deliberately generic "invalid or expired invite", which
/// surfaces to the guest as an EXPIRY problem, sending you looking at TTLs
/// instead of at the link. Splitting it here is what keeps the token a token.
library;

/// A guest invite link's two parts: the JWT and the optional fragment secret.
class GuestLink {
  const GuestLink({required this.token, this.fragmentSecret});

  /// The invite JWT, with any `&k=` suffix removed.
  final String token;

  /// The `k` fragment secret when the link carried one, else null. Not needed
  /// to preview or join (the server does not read it on either path); carried
  /// so the sealing work that motivated it has it available.
  final String? fragmentSecret;

  bool get isEmpty => token.isEmpty;

  /// Split a raw `:token` path parameter into its parts.
  ///
  /// Tolerant on purpose: a link with no `&`, an empty `k`, a stray trailing
  /// `&`, or extra `&a=b` pairs all still yield a usable token, because the
  /// cost of over-trimming (a guest who cannot get in) is much higher than the
  /// cost of ignoring an unknown parameter.
  factory GuestLink.parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return const GuestLink(token: '');

    final amp = s.indexOf('&');
    if (amp < 0) return GuestLink(token: s);

    final token = s.substring(0, amp);
    String? secret;
    for (final part in s.substring(amp + 1).split('&')) {
      if (part.startsWith('k=')) {
        final v = part.substring(2);
        if (v.isNotEmpty) secret = v;
        break;
      }
    }
    return GuestLink(token: token, fragmentSecret: secret);
  }
}
