import 'package:flutter/material.dart';

import 'src/standalone_app.dart';

/// Entry point for the standalone skcode runner (card C-2, spec section 4.1:
/// "Boots with shell == null, a standalone runner with its own capauth
/// login").
///
/// All the subapp UI lives in the skcode_client workspace package; this file
/// only boots the standalone chrome.
void main() {
  runApp(const SkcodeStandaloneApp());
}
