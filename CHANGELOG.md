# Changelog

All notable changes to skchat-app are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning per SemVer.

## [Unreleased]

### Fixed
- **LiveKit data-channel receive path**: `LiveKitCallService._dataCtl` was declared and
  consumed by `LaneService` but never fed — Spaces lanes (in-call chat, whiteboard, docs)
  could send/persist but never received live peer events. Added a per-connection
  `EventsListener` on `DataReceivedEvent` that republishes `{topic, data, sender}` onto
  `_dataCtl`, disposed with the room. This repairs upstream's own lane features.

### Added
- Full sk-standards doc-set: `SOP.md` (9-section + mermaid architecture), `SECURITY.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`.
