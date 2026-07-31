import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/modules/external_modules.dart';

/// The set of gated module ids MUST mirror the server's `EMBED_MODULES`
/// allowlist (`skchat/src/skchat/embed_auth.py`). skcode is deliberately absent:
/// it runs its own gate and its public client shell is safe to expose, so its
/// pane needs no embed token.
void main() {
  group('moduleRequiresEmbedToken', () {
    test('skdashboard and skos require a token', () {
      expect(moduleRequiresEmbedToken('skdashboard'), isTrue);
      expect(moduleRequiresEmbedToken('skos'), isTrue);
    });

    test('case/whitespace tolerant', () {
      expect(moduleRequiresEmbedToken('  SKDashboard '), isTrue);
    });

    test('skcode and skchat do NOT require a token', () {
      expect(moduleRequiresEmbedToken('skcode'), isFalse);
      expect(moduleRequiresEmbedToken('skchat'), isFalse);
    });

    test('unknown module does not require a token', () {
      expect(moduleRequiresEmbedToken('whatever'), isFalse);
    });

    test('the gated set is exactly {skdashboard, skos}', () {
      expect(kEmbedGatedModuleIds, {'skdashboard', 'skos'});
    });
  });
}
