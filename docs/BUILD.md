# Building Flygo Chat

This guide explains how to build Flygo Chat from source and connect it to a chat server. It has three parts:

- **Part A** (sections 1–5): build the app and sign in to an existing Flygo Chat server. The app has no built-in server: users sign in with their work email and the app finds the server. No code changes needed.
- **Part B** (section 6): run in the background and get notifications on Windows.
- **Part C** (section 7): rebrand the app or use your own servers.

---

## Part A. Build and sign in

### 1. Set up your environment

| Component | Version |
|---|---|
| Flutter | **3.47.6**, stable channel. Use this exact version. |
| Git | any |

You also need the tools for each platform you build for:

| Target | Requirements |
|---|---|
| Windows | Windows 10/11 and **Visual Studio 2022** with the "Desktop development with C++" workload |
| macOS | A Mac with Xcode and CocoaPods (`brew install cocoapods`). The app targets **macOS 12.3+** (the screenshot tool uses ScreenCaptureKit) |
| Linux | Ubuntu 22.04+ with: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev libjsoncpp-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libpulse-dev` |
| Android | Android Studio (or the Android SDK) and JDK **17** |
| iOS | A Mac with Xcode and CocoaPods, plus an Apple Developer account |

Run `flutter doctor` and install whatever it reports as missing (✗).

### 2. Get the source

```sh
git clone https://github.com/flygo-technology/flygo-chat.git
cd flygo-chat
flutter pub get
```

### 3. Build

The app already points to the Flygo server, so you don't need to change anything before building.

#### Windows

```powershell
flutter build windows --release
```

The output is in `build\windows\x64\runner\Release\`. Distribute the **whole folder**, not just `flygo_chat.exe`: the app needs the `.dll` files and the `data` folder next to it. The usual approach is to zip the folder; users unzip it and run `flygo_chat.exe`.

No Windows machine? Build on GitHub Actions instead: fork the repo, open the **Actions** tab, run the **windows** workflow, then download `flygo-chat-windows.zip` from the run's Artifacts.

> **White or blank window on some PCs:** Windows builds render with Skia by default because Impeller showed a white window on weak GPUs (for example Intel UHD 730). Set the environment variable `FLYGO_IMPELLER=1` to try Impeller. For startup problems, `%TEMP%\flygo-init.log` records each startup step, and `FLYGO_SHOW=1` shows the window before the first frame.

> On first launch, Windows SmartScreen may show "Windows protected your PC", because your build is not code-signed. Click **More info → Run anyway**. To remove the warning, sign the `.exe` with your organization's code-signing certificate.

#### macOS

```sh
cd macos && pod install && cd ..
flutter build macos --release
```

The output is `build/macos/Build/Products/Release/Flygo Chat.app`. To run it on other Macs, sign it with a Developer ID and notarize it; otherwise macOS will block it. For internal use, users can right-click the app and choose **Open** the first time.

#### Linux

```sh
flutter build linux --release
```

The output is in `build/linux/x64/release/bundle/`. Copy the whole folder and run the `flygo-chat` binary inside it.

#### Android

Android builds need a Firebase config file that is **not in the repository** (the repository is public). Put your own `google-services.json` at `android/app/google-services.json` before building (create an Android app with package `vn.flygo.chat`, or your own package name, in the Firebase console and download the file). The file is listed in `.gitignore`; never commit it. Flygo's release machines copy their copy in just before building.

Android builds **must** specify a flavor with `--flavor`:

```sh
flutter build apk --release --flavor sideload
```

The output is `build/app/outputs/flutter-apk/app-sideload-release.apk`, which can be installed directly on a phone. The `play` flavor is for Google Play only (see section 7).

> Push notifications on Android are tied to Flygo's Firebase project and signing key. A self-built APK can send messages and make calls while the app is open, but may not receive notifications after the app is closed. For reliable notifications, install Flygo Chat from Google Play. A self-built APK also cannot be installed over the Google Play version, because the signatures differ; uninstall the other one first.

#### iOS

iOS only installs builds signed with an Apple Developer account. Users who just need to chat should install **Flygo Chat from the App Store** or TestFlight. Only build for iOS if you are publishing your own app (section 7).

```sh
cd ios && pod install && cd ..
flutter build ipa --release
```

Before building, open `ios/Runner.xcworkspace` in Xcode and select your Team under **Signing & Capabilities**.

### 4. Sign in

1. Open the app and enter your work email (for example `name@example.com`). The app looks for the chat server of that domain (`chat.example.com`) and opens its sign-in page.
2. Sign in with your account on that server: username and password, or **Sign in with Google** if your account uses Google.
3. If you don't have an account, ask your administrator.

Users who use several servers can switch between them with the server selector at the top of the sign-in screen or in the **You** tab.

**Optional: preconfigure company computers.** Before the app's first launch, create a `servers.json` file in the app's data folder:

| OS | Folder |
|---|---|
| Windows | `%APPDATA%\Flygo\Flygo Chat\` |
| macOS | `~/Library/Application Support/vn.flygo.chat/` |
| Linux | `~/.local/share/vn.flygo.chat/` |

```json
{
  "current": "https://chat.example.com",
  "items": [{ "url": "https://chat.example.com", "name": "Example" }]
}
```

### 5. Self-update

The Windows, macOS, Linux and Android APK builds check the server the user is signed in to for new versions (`/static/plugins/flygo-update/version.json`) and offer to update.

- **Unmodified build:** leave self-update on. Users get the release that their server publishes.
- **Modified build:** build with `--dart-define=NO_SELF_UPDATE=true` so the official release doesn't overwrite your version:

  ```sh
  flutter build windows --release --dart-define=NO_SELF_UPDATE=true
  ```

---

## Part B. Windows: background mode and notifications

### 6. Background mode

The Windows app gets messages and calls straight from the server. It does **not** need Firebase or a push server, but **the app must be running**. To make sure it isn't closed by accident, the Windows app has a background mode:

- **Clicking X doesn't quit.** The window goes to the **system tray** (right side of the taskbar, sometimes behind the ˄ arrow), and the app keeps receiving messages and calls. The first time, a short notice explains that the app is still running.
- **Reopening:** click the Flygo Chat icon in the tray, or launch the app as usual. Only one copy runs at a time, so launching it again brings back the hidden window.
- **Quitting:** right-click the tray icon → **Quit**.
- **Start with Windows:** the app starts in the tray every time you sign in to Windows, so you don't miss anything.
- **New message:** a Windows notification appears; clicking it opens that conversation.
- **Incoming call:** the app window pops up and rings.

Both "Keep running when closed" and "Start with Windows" are **on by default**. Users can turn them off under **You → Keep running when closed / Start with Windows**.

Users should also check **Windows Settings → System → Notifications** to make sure Flygo Chat is allowed to show notifications, and that **Do not disturb / Focus** isn't blocking them.

### 6.1. Split panes and pop-out windows (desktop)

On desktop (and tablets in landscape) the content area can be split into up to four panes (2x2):

- Drag a conversation from the chat list, or a section from the navigation bar (Chats, Assistants, Tasks, Threads, You), onto the content area. Drop on an edge to split, in the middle to replace.
- Each pane header has maximize, pop out and close buttons; drag a header to move or swap panes; drag a divider to resize (double-click to reset).
- Shortcuts (Cmd on macOS, Ctrl elsewhere): **1–4** focus a pane, **W** closes the focused pane, **K** opens the quick switcher.
- The layout is saved per server and restored on the next launch.

Dragging a conversation or pane outside the window (or pressing the pop-out button) opens it in its own window. Each pop-out is a separate app process started with `--popout --server=<url> --chat=<channel id>` (or `--section=<name>`); it reuses the saved session, so no token is passed on the command line. Only the main window owns the tray, notifications, sounds, autostart, the updater and the AI runner. Up to four pop-outs are kept; they reopen at their last position when the app starts.

> macOS and Linux don't have a background mode yet: closing the window quits the app. Users should minimize the window instead of closing it to keep getting notifications.

---

## Part C. Customization and your own servers

### 7. Customization

Read this part only if you want to publish the app under your own brand, or run it against your own self-hosted chat server.

> Under the [LICENSE](../LICENSE), running the app with your own organization's server is allowed. Rebranding, distributing builds, or hosting the app for other organizations requires a **written agreement with Flygo Technology** first.

#### 7.1. What to change

| Item | Location | Current value |
|---|---|---|
| Servers | none built in | users sign in by email; optional `servers.json` (section 4) |
| Push station | `lib/config.dart` `pushUrlFor` | `https://push.<server domain>` of the signed-in server |
| Speech-to-text | `lib/config.dart` `kSttUrl` | `https://stt.<server domain>` |
| Update channel, runner download, sounds, stickers, speech model | `lib/config.dart` `staticBase` | `<server>/static/plugins/flygo-update` and `flygo-agent` on the signed-in server |
| App name | `macos/Runner/Configs/AppInfo.xcconfig`, `ios/Runner/Info.plist`, `android/app/src/main/AndroidManifest.xml`, `windows/runner/Runner.rc`, `windows/runner/main.cpp`, `linux/` | `Flygo Chat` |
| Bundle ID / package name | `android/app/build.gradle.kts`, `ios/Runner.xcodeproj`, `macos/Runner/Configs/AppInfo.xcconfig`, `linux/CMakeLists.txt` | `vn.flygo.chat` |
| Apple Team ID | `ios/Runner.xcodeproj/project.pbxproj` (`DEVELOPMENT_TEAM`) | Flygo's team |
| Firebase (Android) | `android/app/google-services.json` (not in git, see section 3) | Flygo's project |
| Google sign-in URL scheme | `lib/config.dart` `kMobileScheme`, `macos/Runner/Info.plist`, AndroidManifest | `flygochat` |
| Icons and colors | `assets/icon/`, `flutter_launcher_icons.yaml`, `lib/config.dart` `WaColors` | Flygo branding |

Never reuse Flygo's certificates, signing keys, Team ID or Firebase project.

#### 7.2. Your own servers

- **Chat server:** enable password sign-in and/or Google SSO, and enable the Calls plugin if you need voice and video calls. Users sign in with their email (the app finds `chat.<email domain>`), or you preconfigure `servers.json`.
- **Static files:** put the update channel, runner, sounds, stickers and speech model in the chat server's client plugins folder (`client/plugins/flygo-update`, `client/plugins/flygo-agent`), served at `/static/plugins/…`.
- **Push station:** the app looks for `https://push.<server domain>/health`. For example, if the server is `chat.example.com`, the app checks `push.example.com`. If it is found, the app uses it for:
  - the device registry;
  - stopping the ringing on other devices once one device answers;
  - TURN for calls;
  - saving stickers.

  Each server uses only its own station; without one, these features are unavailable.
- **Mobile push notifications:**
  - The app registers its device with the chat server as `android_rn-v2:flygo.<FCM token>` or `apple_rn-v2:flygo.<apns>-<voip>`.
  - Your push server must recognize the `flygo.` prefix and deliver through FCM/APNs using your own keys. iOS calls use VoIP push with the topic `<bundle id>.voip`.
  - The push server source is not in this repository. Contact Flygo if you need it.
- **AI assistants and speech-to-text:** speech-to-text needs its own service. AI assistants need the runner described in [Part D](#part-d-ai-assistant-runner); bot-to-bot calls (A2A) and schedules also go through the relay in `agent/relay/`. Without them the app still works; those features are just hidden or unavailable.

#### 7.3. Signing and publishing

- **Google Play:** build with `flutter build appbundle --release --flavor play`. Declare the upload key in `android/key.properties`, which must stay out of git:

  ```properties
  storeFile=/path/to/upload.jks
  storePassword=...
  keyAlias=upload
  keyPassword=...
  ```

- **App Store:** run `flutter build ipa`, then upload with Xcode Organizer or Transporter.
- **Self-updates:** `tool/publish_update.sh` publishes them to a server over SSH. Before using it, set `FLYGO_UPDATE_HOST` and `FLYGO_UPDATE_DIR` as environment variables or in `tool/local.env`, which stays out of git.

---

## Part D. AI assistant runner

### 8. What the runner is

AI assistants are chat server bots driven by **flygo-agent**, a small program in `agent/` (TypeScript, compiled with [Bun](https://bun.sh) into a single executable). It runs on the bot owner's own computer, never on the chat server, and uses that person's Codex, Claude Code or Antigravity (`agy`) account. The desktop apps ship with the runner inside, and install and update it automatically.

| Path | Contents |
|---|---|
| `agent/src/` | Runner: `cli.ts` (commands), `runner.ts` (chat loop), `engines/` (Codex, Claude, Antigravity), `mcp-chat.ts` (chat tools for the model), `schedule.ts` (schedules), `a2a.ts` (bot-to-bot calls) |
| `agent/relay/a2a.mjs` | A2A, schedule and remote-skill relay, mounted in the push station at `/a2a` |
| `agent/relay/tasks.mjs` | Task reminders (assigned, due tomorrow, overdue, done) and the 08:00 morning digest, sent by a notification bot; deploy steps in `agent/README.md` |
| `agent/README.md` | Protocol details: post props, approvals, questions, schedules, A2A |
| `agent/config.example.json` | Example runner configuration |

### 9. Build the runner

Install Bun 1.4 or newer, then:

```sh
cd agent
bun install --frozen-lockfile
bun scripts/build.ts                  # every platform
bun scripts/build.ts windows-x64      # or just the ones you need
```

The executables and a `version.json` (version, sizes, SHA-256) are written to `agent/dist/`. Supported targets: `darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`, `windows-x64`. Type-check with `bun run check`.

### 10. Bundle it into the desktop apps

After `flutter build`, run `tool/bundle_runner.sh` on the build output:

```sh
tool/bundle_runner.sh macos "build/macos/Build/Products/Release/Flygo Chat.app"
tool/bundle_runner.sh linux-x64 build/linux/x64/release/bundle
tool/bundle_runner.sh windows-x64 build/windows/x64/runner/Release
```

When Bun is installed, the script builds the runner from `agent/`, so the bundled runner always matches the app's commit. Without Bun, or with `FLYGO_RUNNER_FROM=download`, it downloads the published runner instead. The GitHub Actions Windows workflow installs Bun and builds from source.

### 11. Run a bot

1. Create a bot on the chat server (or from the app's assistant settings). The app sets up the bot description marker and the runner automatically.
2. To run it by hand: copy `agent/config.example.json` to `~/.config/flygo-agent/config.json`, fill in the server, bot token and owner, then run `flygo-agent doctor` and `flygo-agent run`. `flygo-agent install-service --config <file>` keeps it running as a background service.
3. The owner's computer needs the Codex CLI, Claude Code or Antigravity CLI (`agy`) installed and signed in. The app's "New AI assistant" screen can install each engine and opens its sign-in.

> **Antigravity:** `agy` has no headless login; sign in once interactively (`agy`, choose Google) on the machine itself. A login made over SSH is stored in a file, while background services read the system keychain, so they won't see it. `GEMINI_API_KEY` is an alternative. Each turn runs `agy -p --output-format stream-json`, resumes with `--conversation`, and gets the runner's MCP tools, hooks and persona through a private per-turn folder passed with `--add-dir`.

