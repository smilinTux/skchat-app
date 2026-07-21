/// The trust tier of an identity, orthogonal to encryption (spec section 2).
/// red   = fresh / self-asserted (trust-on-first-use). The default.
/// amber = provisional (safety-number verified or vouched by a green). Modeled
///         now, earned only via flows that ship later.
/// green = sovereign (this device holds a live enrolled operator session).
enum SelfTrustTier { red, amber, green }

/// A resolved "who am I, and how trusted am I" snapshot for THIS device.
///
/// [pgpKeyId]/[pgpKeySize] are meaningful only when [tier] is green (the
/// sovereign daemon identity); a red guest carries empty/zero for them and
/// must never be shown the operator's key. [degraded] is true when the
/// per-device identity had to fall back to an in-memory value because secure
/// storage was unavailable (privacy browsers), so the UI can warn that the
/// identity will not persist across reloads.
class SelfIdentity {
  const SelfIdentity({
    required this.displayName,
    required this.id,
    required this.fingerprint,
    required this.tier,
    required this.isOperator,
    this.pgpKeyId = "",
    this.pgpKeySize = 0,
    this.degraded = false,
  });

  final String displayName;
  final String id;
  final String fingerprint;
  final SelfTrustTier tier;
  final bool isOperator;
  final String pgpKeyId;
  final int pgpKeySize;
  final bool degraded;

  /// The sovereign operator identity (green). Values come from the daemon.
  factory SelfIdentity.operator__({
    required String displayName,
    required String fingerprint,
    required String pgpKeyId,
    required int pgpKeySize,
  }) =>
      SelfIdentity(
        displayName: displayName,
        id: fingerprint,
        fingerprint: fingerprint,
        tier: SelfTrustTier.green,
        isOperator: true,
        pgpKeyId: pgpKeyId,
        pgpKeySize: pgpKeySize,
      );

  /// A self-asserted per-device identity (red). No operator key is exposed.
  factory SelfIdentity.guest({
    required String displayName,
    required String fingerprint,
    bool degraded = false,
  }) =>
      SelfIdentity(
        displayName: displayName,
        id: fingerprint,
        fingerprint: fingerprint,
        tier: SelfTrustTier.red,
        isOperator: false,
        degraded: degraded,
      );

  SelfIdentity copyWith({
    String? displayName,
    String? id,
    String? fingerprint,
    SelfTrustTier? tier,
    bool? isOperator,
    String? pgpKeyId,
    int? pgpKeySize,
    bool? degraded,
  }) =>
      SelfIdentity(
        displayName: displayName ?? this.displayName,
        id: id ?? this.id,
        fingerprint: fingerprint ?? this.fingerprint,
        tier: tier ?? this.tier,
        isOperator: isOperator ?? this.isOperator,
        pgpKeyId: pgpKeyId ?? this.pgpKeyId,
        pgpKeySize: pgpKeySize ?? this.pgpKeySize,
        degraded: degraded ?? this.degraded,
      );

  @override
  bool operator ==(Object other) =>
      other is SelfIdentity &&
      other.displayName == displayName &&
      other.id == id &&
      other.fingerprint == fingerprint &&
      other.tier == tier &&
      other.isOperator == isOperator &&
      other.pgpKeyId == pgpKeyId &&
      other.pgpKeySize == pgpKeySize &&
      other.degraded == degraded;

  @override
  int get hashCode => Object.hash(displayName, id, fingerprint, tier,
      isOperator, pgpKeyId, pgpKeySize, degraded);
}
