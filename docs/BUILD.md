# Building Flygo Chat

This guide explains how to build Flygo Chat from source and connect it to the Flygo server. It has three parts:

- **Part A** (sections 1–5): build the app for the **Flygo server** (`https://chat.flygo.vn`). This is the simplest path: no code changes, and no servers to set up.
- **Part B** (section 6): run in the background and get notifications on Windows.
- **Part C** (section 7): rebrand the app or use your own servers.

---

## Part A. Build for the Flygo server

### 1. Set up your environment

| Component | Version |
|---|---|
| Flutter | **3.47.6**, stable channel. Use this exact version. |
| Git | any |

You also need the tools for each platform you build for:

| Target | Requirements |
|---|---|
| Windows | Windows 10/11 and **Visual Studio 2022** with the "Desktop development with C++" workload |
| macOS | A Mac with Xcode and CocoaPods (`brew install cocoapods`) |
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

### 4. Sign in to the Flygo server

1. Open the app. The sign-in screen uses the **Flygo** server (`chat.flygo.vn`) by default.
2. Sign in with your Flygo account: username and password, or **Sign in with Google** if your account uses Google.
3. If you don't have an account, ask your Flygo administrator.

If a user switched to a different server by mistake, they can tap the server selector at the top of the sign-in screen (or in the **You** tab) and choose **Flygo** again.

**Optional: preconfigure company computers.** Before the app's first launch, create a `servers.json` file in the app's data folder:

| OS | Folder |
|---|---|
| Windows | `%APPDATA%\Flygo\Flygo Chat\` |
| macOS | `~/Library/Application Support/vn.flygo.chat/` |
| Linux | `~/.local/share/vn.flygo.chat/` |

```json
{
  "current": "https://chat.flygo.vn",
  "no_default": true,
  "items": [{ "url": "https://chat.flygo.vn", "name": "Flygo" }]
}
```

### 5. Self-update

The Windows, macOS, Linux and Android APK builds check the Flygo server for new versions and offer to update.

- **Unmodified build:** leave self-update on. Users will get the latest official Flygo release.
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

> macOS and Linux don't have a background mode yet: closing the window quits the app. Users should minimize the window instead of closing it to keep getting notifications.

---

## Part C. Customization and your own servers

### 7. Customization

Read this part only if you want to publish the app under your own brand, or run it against your own Mattermost server.

> Under the [LICENSE](../LICENSE), rebranding, using your own servers, or distributing the app requires a **written agreement with Flygo Technology** first.

#### 7.1. What to change

| Item | Location | Current value |
|---|---|---|
| Default server | `lib/config.dart` `kDefaultServer` | `https://chat.flygo.vn` |
| Default server display name | `lib/data/servers.dart` | `Flygo` |
| Shared push station | `lib/config.dart` `kFlygoPush` | `https://push.flygo.vn` |
| Speech-to-text | `lib/api/stt.dart` `kSttUrl` | `https://stt.flygo.vn` |
| Update download location | `lib/update/updater.dart` `base` | Flygo server |
| AI runner download location | `lib/agent/agent_service.dart` `downloadBase` | Flygo server |
| Privacy and support pages | `lib/config.dart` `kPrivacyUrl`, `kSupportUrl` | Flygo pages |
| App name | `macos/Runner/Configs/AppInfo.xcconfig`, `ios/Runner/Info.plist`, `android/app/src/main/AndroidManifest.xml`, `windows/runner/Runner.rc`, `windows/runner/main.cpp`, `linux/` | `Flygo Chat` |
| Bundle ID / package name | `android/app/build.gradle.kts`, `ios/Runner.xcodeproj`, `macos/Runner/Configs/AppInfo.xcconfig`, `linux/CMakeLists.txt` | `vn.flygo.chat` |
| Apple Team ID | `ios/Runner.xcodeproj/project.pbxproj` (`DEVELOPMENT_TEAM`) | Flygo's team |
| Firebase (Android) | `android/app/google-services.json` | Flygo's project |
| Google sign-in URL scheme | `lib/config.dart` `kMobileScheme`, `macos/Runner/Info.plist`, AndroidManifest | `flygochat` |
| Icons and colors | `assets/icon/`, `flutter_launcher_icons.yaml`, `lib/config.dart` `WaColors` | Flygo branding |

Never reuse Flygo's certificates, signing keys, Team ID or Firebase project.

#### 7.2. Your own servers

- **Mattermost:** enable password sign-in and/or Google SSO, and enable the Calls plugin if you need voice and video calls. Users can add your server in the app, or you can change `kDefaultServer` and rebuild.
- **Push station:** the app looks for `https://push.<server domain>/health`. For example, if the server is `chat.example.com`, the app checks `push.example.com`. If it is found, the app uses it for:
  - the device registry;
  - stopping the ringing on other devices once one device answers;
  - TURN for calls;
  - saving stickers.

  If it isn't found, the app uses Flygo's shared push station.
- **Mobile push notifications:**
  - The app registers its device with Mattermost as `android_rn-v2:flygo.<FCM token>` or `apple_rn-v2:flygo.<apns>-<voip>`.
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

AI assistants are Mattermost bots driven by **flygo-agent**, a small program in `agent/` (TypeScript, compiled with [Bun](https://bun.sh) into a single executable). It runs on the bot owner's own computer, never on the chat server, and uses that person's Codex or Claude account. The desktop apps ship with the runner inside, and install and update it automatically.

| Path | Contents |
|---|---|
| `agent/src/` | Runner: `cli.ts` (commands), `runner.ts` (chat loop), `engines/` (Codex, Claude), `mcp-chat.ts` (chat tools for the model), `schedule.ts` (schedules), `a2a.ts` (bot-to-bot calls) |
| `agent/relay/a2a.mjs` | A2A and schedule relay, mounted in the push station at `/a2a` |
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

1. Create a bot in Mattermost (or from the app's assistant settings). The app sets up the bot description marker and the runner automatically.
2. To run it by hand: copy `agent/config.example.json` to `~/.config/flygo-agent/config.json`, fill in the server, bot token and owner, then run `flygo-agent doctor` and `flygo-agent run`. `flygo-agent install-service --config <file>` keeps it running as a background service.
3. The owner's computer needs the Codex CLI or Claude Code installed and signed in.

