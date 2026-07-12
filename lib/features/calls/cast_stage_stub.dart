import "package:flutter/material.dart";

/// Non-web stub for the TV-cast stage.
///
/// Casting is a Flutter-web feature (it drives a browser `<video>` element plus
/// the Google Cast SDK / AirPlay via JS interop), so on native targets the
/// controller is inert and the stage renders a short explanatory placeholder.
/// The web side lives in `cast_stage_web.dart`; the two are selected by a
/// conditional import in `cast_sheet.dart`.
class CastController {
  CastController(this.hlsUrl);

  /// The room's public HLS URL (still useful for the "Open on TV" fallback).
  final String hlsUrl;

  /// Called by [CastStage] once the surface is mounted. No-op off web.
  void mountWhenReady() {}

  bool chromecastAvailable() => false;

  bool airplayAvailable() => false;

  void showAirplay() {}

  Future<bool> requestChromecast() async => false;

  void dispose() {}
}

CastController createCastController(String hlsUrl) => CastController(hlsUrl);

/// Placeholder surface shown on non-web targets.
class CastStage extends StatelessWidget {
  const CastStage({super.key, required this.controller});

  final CastController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF000000),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: const Text(
        "Casting to a TV is available in the web app.",
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }
}
