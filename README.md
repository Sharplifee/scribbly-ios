# Scribbly iOS

Native SwiftUI app. Background-durable voice recording that survives calls, Siri,
route changes, and app suspension — only the Finish button ends a recording.

- `Sources/Recorder.swift` — AVAudioSession + segmented AVAudioRecorder, interruption/route/media-reset recovery
- `Sources/Uploader.swift` — background URLSession upload to /api/voice (survives app termination)
- `Sources/ScribblyApp.swift` — SwiftUI UI + embedded library webview

Bundle `com.connor.scribbly` · Team XF783932R2 · CI: `.github/workflows/ios.yml` (macos-15, no Mac required)
