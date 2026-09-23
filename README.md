# Newton — a Swift agent harness for iOS

A first implementation of a native iPhone agent: SwiftUI app, durable chats,
approval-gated tools, on-device GGUF inference, OpenAI-compatible APIs, and Apple's
on-device speech recognition. Requires **iOS 17+**, **Xcode with Swift 6+**, and a
**iPhone/iPad or iOS Simulator**. No account, analytics SDK, or cloud database
is bundled.

## Run

1. Open `Newton.xcodeproj` in Xcode.
2. Select the **Newton** scheme and your connected device or an iPhone simulator.
   The pinned llama.cpp XCFramework includes both iOS-device and simulator slices.
3. Select your development team and a unique bundle ID in Signing & Capabilities.
4. Let Swift Package Manager resolve the pinned binary, then run.
5. Open Settings, configure inference, and tap **Save**.

The project is checked in. After adding app source files, regenerate it with
`python3 Scripts/generate_project.py`; no XcodeGen dependency is needed.

### If Run starts PreviewShell instead of Newton

Open **Newton.xcodeproj**, not the repository folder or `Package.swift`. The toolbar
scheme must be **Newton**, not **Newton-Package**. The same mistake also shows up in the
editor as `Unable to resolve module dependency: 'NewtonCore'` on `App/Newton/AppModel.swift`
(and similar import errors across the app files): the package workspace has no target for
`App/Newton`, so only the Xcode project can compile the app. Close the package workspace —
optionally delete its `DerivedData/newton-agent-*` folder — and reopen `Newton.xcodeproj`.
The package contains the reusable
libraries; the Xcode project contains the runnable iOS app. Running the package scheme
can start Apple's PreviewShell and emit preview-service logs without installing Newton.
Choose the Newton app scheme and your device/simulator, then press Command-R.

### OpenAI-compatible inference

Enter the **base URL including its version prefix**, model ID, and optional API key.
Newton appends `/chat/completions`.

| Server | Example base URL |
| --- | --- |
| HTTPS deployment | `https://your-server.example/v1` |
| llama.cpp / LM Studio on your computer | `http://your-computer.local:8080/v1` (use your actual port) |
| Ollama compatibility endpoint | `http://your-computer.local:11434/v1` |

Use the computer's reachable LAN hostname/address on iPhone, not `localhost`. The server
must listen on the LAN and its firewall must allow connections. iOS requests local-network
permission as needed. The app enables `NSAllowsLocalNetworking`, not a global arbitrary-load
exception. Prefer HTTPS; HTTP behavior for numeric addresses varies across iOS releases,
so use a `.local` hostname or HTTPS if ATS blocks a connection.

The server/model must implement Chat Completions and function calling
(`tools`, `tool_calls`, `tool_call_id`). Servers that reject tools return an error.
API replies **stream** (`stream: true` with SSE deltas): answers render live with a
token/sec readout in a small circular badge floating on the transcript just above the input
bar, aligned with the submit button; it remains shown afterwards at its last value until the
next message. Every completed generation also persists its starting context size and average
token rate with the chat; tapping the badge opens a generation performance chart (context-size
bars and a token-rate line over recent generations, each axis normalized to its own maximum,
with per-generation detail on tap). Streamed tool calls are reassembled from
fragments before execution. Servers that ignore the stream flag and reply with a normal
JSON body are still accepted. The on-device GGUF runtime streams plain-text answers token by
token with the same live readout; tool-mode replies stay buffered because the model emits them as
a single raw JSON envelope, and flashing partial envelope syntax on screen would be noise.
Responses API, model discovery, automatic retries, and context compaction are not implemented. **Chat and approved tool results are sent to the configured endpoint.**

### On-device inference

In Settings, open **Download from Hugging Face**, enter a public repository URL or
`owner/model-GGUF`, and tap **Find GGUF files**. Choose a single-file GGUF using the
listed sizes and tap its download icon. Progress and cancellation appear while it
transfers; completed files are listed under **Downloaded models**. Tap **Use for
inference**, then **Save** to use one locally. Private/gated repositories and split
GGUF sets are not supported by this downloader.

Every downloaded model has a **red trash button**. It opens a confirmation showing
the filename and space to reclaim. Cancel keeps the file; Delete removes its local
bytes and inventory entry, and clears the selected model if necessary. Chats remain.
Repository downloads are pinned to the listed revision, size-checked before being
saved, and copied into the same uninstall-removable model store as file imports.


Choose **On-device GGUF**, import from Files or enter a direct HTTPS download URL, select
the imported model, and Save. Keep the app open during download/import. Import only trusted
models: checking the GGUF magic header catches HTML downloads, not every malformed file.

The runtime uses **llama.cpp b9049**, pinned by URL and SHA-256 in `Package.swift`. Choose
a small quantized instruction/chat GGUF that fits device memory and includes a supported
chat template. Oversized models may cause iOS to terminate the app. This version has no
model compatibility catalog or reliable memory estimator. Not every GGUF architecture
or chat template is supported.

The adapter uses the model's chat template, a 4,096-token context, up to 512 output tokens,
greedy sampling, and an explicit JSON envelope for tool calls. Invalid envelopes are
shown as text and never executed. Tool quality depends on the model; grammar-constrained
decoding and model-specific tool templates remain follow-ups. Loaded model weights stay
resident between messages (one model at a time; freed when a model is deleted or all data
is erased), so follow-up messages do not pay for a second full GGUF load. The KV cache is
allocated per answer and sized to the actual prompt plus the output budget rather than to
the full context ceiling.

### If Xcode reports a missing simulator library

The original b10549 dependency lacked the simulator slice. The project now pins b9049,
which includes both `ios-arm64` and `ios-arm64_x86_64-simulator`. After updating, use
**File → Packages → Resolve Package Versions**, then **Product → Clean Build Folder**.
If the error still names b10549, use **File → Packages → Reset Package Caches** and resolve
again. Open `Newton.xcodeproj` and select the **Newton** app scheme, rather than a package
library scheme. A simulator named “iPhone” is still a simulator; for hardware, select your
connected phone under iOS Devices. This fix supports either destination. Messages and
on-device speech availability still require physical-device checks.

## Tools

Use **Settings → Tools → Enable tools**, then **Save**, to switch tools on or off.
Off applies to both local and API inference: no tool definitions are sent and tool
execution is blocked. Local models receive an ordinary chat prompt instead of the
JSON tool protocol. Existing installations keep tools enabled until changed.

Every model-requested tool, including private-data reads, requires an **Allow once**
review. System permissions and the Messages Send button are additional user controls.

| Tool | Behavior |
| --- | --- |
| `messages_compose` | Apple's composer with one explicit recipient and body. User taps Send. No inbox access, silent send, contact-name resolution, delivery confirmation, or forced iMessage transport. |
| `calendar_list` | Up to 100 events in a maximum 31-day range through EventKit. |
| `calendar_create` | Creates an event in the default writable calendar. |
| `calendar_update` / `calendar_delete` | Use an exact event ID. Recurring events are rejected. |
| `notes_search/create/update/delete` | CRUD for **Newton's private notes**, also editable directly in the Notes UI. |
| `apple_notes_create` | Hands text to a named user-installed Shortcut. Reports handoff, not verified creation. |

### Apple Notes setup

1. Create a Shortcut called **Newton — Create Note**, or configure a custom name in Newton.
2. Add **Create Note**, use **Shortcut Input** as its body, and choose a folder.
3. Test the Shortcut with text, then invoke `apple_notes_create` from Newton.

This uses Apple's `shortcuts://run-shortcut?name=…&input=text&text=…` URL scheme.
There is no direct Apple Notes database integration. Reading, editing, and deleting
existing Apple Notes are not implemented. The handoff may background Newton, completion
is not assumed, and actions are never automatically replayed.

### Dictation

Tap the microphone, review/edit the draft, and tap Send yourself. `SFSpeechRecognizer`
uses `requiresOnDeviceRecognition = true` only if the recognizer supports it. Unsupported
devices/languages show an error rather than uploading audio. Permissions are requested
just in time. Recording stops on backgrounding or audio interruption. No audio is saved.
iOS owns and manages its system speech resources.

## Storage and removal

All Newton-owned files are in `Library/Application Support/Newton/`:

```text
Newton/
  chats.json          # messages, tool calls/results, titles
  settings.json       # endpoint, API key, provider, Shortcut name
  notes.json          # private notes
  models.json         # model inventory
  Models/<UUID>.gguf  # owned copies of model files
```

Writes are atomic and use complete iOS file protection. The root is excluded from backup.
Credentials deliberately live in the protected app container instead of Keychain, whose
entries can survive uninstall. No app group, iCloud store, or persistent networking cache
is used. Read errors preserve existing files and disable writes rather than replacing data.
This version uses Codable JSON, without migrations, pagination, or large-history indexing.
OS file protection can cause operations to fail while the device is locked.

**Delete App** removes the container and its models. **Offload App** retains data. Settings
also provides **Erase all Newton data**. iOS has no uninstall hook for undoing external
actions: sent messages, Calendar events, exported Apple Notes, original model files in
Files, API-provider copies, and OS-managed speech resources are outside Newton's container.
Those are not deleted with Newton.

## Architecture

```text
SwiftUI AppModel → AgentRuntime → ChatInference
                       │          ├─ CompatibleInference (URLSession)
                       │          └─ LlamaInference (actor + llama.cpp)
                       └─ AgentTool registry → approval → native tools
                 SandboxStore ← durable intent/result checkpoints
```

- `Sources/NewtonCore`: Codable state, storage, schemas, model protocol, compatible
  transport, and bounded orchestration.
- `Sources/NewtonLocal`: actor-confined C pointers, template application, tokenization,
  prompt batches, cancellation, and native resource cleanup.
- `App/Newton`: chat/settings/notes UI, approvals, importing, EventKit, MessageUI,
  Shortcuts, and Speech/AVAudioEngine.
- `Tests/NewtonCoreTests`: approvals, arguments, persistence ordering, crash recovery,
  cancellation, loop limits, deletion, and HTTP inference behavior.

The loop allows eight rounds and eight calls per round. It checkpoints intent before
execution. Missing results after a crash are marked **outcome unknown** and never replayed
automatically. Cancellation is checked between calls and local decode batches. There is
no guaranteed background agent execution, scheduling, MCP, or multi-agent runtime yet.

## Validation

```sh
swift test
python3 Scripts/check_ios.py
python3 Scripts/check_ios.py --simulator
xcodebuild -project Newton.xcodeproj -scheme Newton \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The initial validation passed **16 automated tests** (including SSE streaming, tool-call
fragment reassembly, and non-streaming fallback). `check_ios.py` compiles and links
all app/library sources directly against the device or simulator SDK. It does not package/sign an app
or validate Xcode resource/framework embedding.

Full unsigned Xcode builds for both iOS device and iOS Simulator now pass with b9049. The earlier local
Xcode developer-framework mismatch no longer reproduces. Code-signing and installation
on your physical device still require your development team and provisioning settings.

Before a device beta, verify:

- Signing/install, real API chat, and multi-tool approvals on iPhone.
- Denial/cancellation, native composer outcomes, and background/foreground transitions.
- EventKit permissions, read-only calendars, and event IDs.
- Shortcuts setup and user verification of exported notes.
- Dictation permissions, interruptions, and unsupported locales.
- Actual GGUF inference, memory pressure, cancellation, and switching models.
- Delete/reinstall versus offload, failed imports, and low storage.

An app privacy manifest is included for app-owned file access. App Store distribution
still needs an icon, signing, privacy disclosures for the selected server behavior, and
a required-reason API/license review of the native dependency.

## Primary references

- [MessageUI composer](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller)
- [EventKit access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)
- [On-device recognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [Run a Shortcut by URL](https://support.apple.com/guide/shortcuts/apd624386f42/ios)
- [Backup exclusion](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)
- [llama.cpp XCFramework](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md)
- [Pinned upstream Swift example](https://github.com/ggml-org/llama.cpp/tree/b9049/examples/llama.swiftui)
