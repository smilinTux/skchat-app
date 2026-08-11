// Export shim (reconciled spec 3.2 step 2).
//
// The Sovereign Glass theme (colors, typography, ThemeData, glass widgets)
// MOVED into the `skchat_ui` workspace package under
// `packages/skchat_ui/lib/src/theme/`. This barrel stays at its original path
// and re-exports the moved surface so every existing importer keeps resolving
// unchanged. New code should import `package:skchat_ui/skchat_ui.dart`.
export 'package:skchat_ui/skchat_ui.dart'
    show
        SovereignColors,
        SovereignDensity,
        SovereignSpacing,
        SovereignSpacingLadder,
        SovereignTypeExtras,
        SovereignTypography,
        SovereignTheme,
        GlassCard,
        GlassNavBar,
        SoulAvatar,
        EncryptBadge,
        DeliveryStatus;
