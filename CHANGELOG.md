# Changelog

Build numbers are the `+N` part of `pubspec.yaml` (`1.0.0+N`). The runner version is in `agent/package.json`.

## 272 (2026-10-31)
- Tasks: the Boards button opens a bottom sheet listing boards with task counts; picking one filters the Tasks list (chip "Board: ...", All / Mine toggle).
- Boards on phones stack vertically (kanban columns as sections, table rows as cards, two-column gallery); no horizontal scrolling.
- Tapping a task opens its detail full screen on phones.
- `android/app/google-services.json` is no longer tracked in git; build machines copy it in.

## 271 (2026-10-31)
- Tasks tab redesign: "My tasks" summary, filters (Today, This week, Overdue, Assigned by me, All), grouping by due date, tap the circle to complete with undo, swipe to complete or reschedule, long-press menu, quick-add sheet, skeleton loading.
- Task detail: large title, tappable status, fact chips, checklist progress, chat-style comments, bottom bar (Mark done, Message assignee, Edit).
- Create a task from a chat message (long press); optional card posted to the chat; "Open original message".
- Relay `relay/tasks.mjs`: reminders when assigned, the day before the due date, when overdue and when done, plus an 08:00 digest (opt-out in You).

## 270 (2026-10-30), runner 0.6.62
- Desktop split panes (up to 2x2) with drag and drop, pane headers, shortcuts and saved layout.
- Pop-out windows (drag outside or pop-out button); main window keeps tray, notifications, updater and runner.
- Antigravity CLI (`agy`) as a third assistant engine.

## 269 (2026-10-30), runner 0.6.61
- Runner chat toolset for agents: list, read, search, send, reply, forward, schedule, polls, cards, reactions, pins, reminders, create chats, members, private threads, bot status.
- Edit a bot's skills remotely through the A2A relay; the Skills tab groups skills per bot (collapsible).

## 268 (2026-10-30)
- Tapping a task opens a read-only detail view with an Edit toggle.

## 267 (2026-10-30)
- You page: activity and custom status on one line.

## 266 (2026-10-30), runner 0.6.60
- Fixed the first message of a new AI session not being sent.
- Runner tools to rename, fork and hand off AI sessions and to manage projects; cards for forked and handed-off sessions.

## 265 (2026-10-30)
- Agents tab: four sub-tabs (Projects, Chat, Schedules, Skills) and AI sessions of ordinary conversations.
- You page: QR login after Settings; Delete account and Sign out are small long-press buttons.
- Relay: `ref_post` can post into direct and group messages.

## 264 (2026-10-29)
- macOS image paste fixed (temp directory created at startup); paste diagnostics log.

## 263 (2026-10-28)
- Password page and forced password change on first login.
- Desktop screenshot button above the composer; paste images on all platforms.
- macOS minimum raised to 12.3.

## 262 (2026-10-27)
- iOS permission texts explain each use with an example (App Store 5.1.1(ii)).

## 261 (2026-10-26)
- Windows: system tray setup no longer blocks the first frame (white window on some PCs).

## 260 (2026-10-26)
- Desktop startup log (`%TEMP%\flygo-init.log`), time limit on startup steps, `FLYGO_SHOW=1`.

## 259 (2026-10-26)
- Windows renders with Skia instead of Impeller by default (white window on weak GPUs); `FLYGO_IMPELLER=1` opts back in.

## 258 (2026-10-26)
- Direct messages with bots are listed like other chats.

## 257 (2026-10-26)
- Tasks tab header becomes a board picker.

## 256 (2026-10-26)
- Boards: native screens (kanban, table, calendar, gallery, card detail) replace the web view.

## 255 (2026-10-26), runner 0.6.59
- Channel names encode sub/AI channel relations; `task_*` MCP tools for agents.
