# Changelog

## 1.3.2 beta — 2026-09-16

- Protect PCM converter input ownership when its sendable callback is invoked
  concurrently.
- Keep connection setup instructions readable on narrow screens.

## 1.3.1 beta — 2026-09-16

- Improve on-device translation with recent conversation context on macOS 26.4
  and later. As the conversation continues, recent translations can update while
  retaining their original speaker and timestamp.
- Add accessibility support for VoiceOver announcements, keyboard focus and
  navigation, visible status labels, and macOS text, contrast, motion, and
  transparency preferences.
- Transcribe saved recordings, continue incomplete work, transcribe again with
  different languages, or rerun translation. Pause and resume processing, compare
  the current and new results, then apply or discard the new result.
- Reduce unnecessary interface updates during audio capture and limit retained
  announcement history.
- Improve recording metadata validation and audio driver stability.

Contextual translation requires macOS 26.4 or later; earlier supported systems
translate each entry individually.
