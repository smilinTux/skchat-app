import 'package:flutter/material.dart';

import 'src/standalone_app.dart';

/// Entry point for the standalone skchat runner (reconciled spec 3.2 step 3).
///
/// Deploys to :8088 until the umbrella cutover. All the subapp UI lives in the
/// skchat_ui workspace package; this file only boots the standalone chrome.
void main() {
  runApp(const SkchatStandaloneApp());
}
