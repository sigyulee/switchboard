# Source provenance

Repository: https://github.com/ExistentialAudio/BlackHole

Commit: ffcb74433fbcf8c8ca5c736677c1a4864384dc09

BlackHole.c and BlackHole.plist are unmodified upstream material. Product-specific names, UIDs, channel count, and factory IDs are supplied by the build. Three separate bundles provide independent state; the upstream mirror is not used as a second bus.

Local patches validate property contracts and retain box-name snapshots while holding the shared-state lock. `patches/patch-lock.json` pins the patches and prepared source digest.
