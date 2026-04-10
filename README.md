<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.0+-black?logo=apple" />
  <img src="https://img.shields.io/badge/Swift-5.0-orange?logo=swift" />
  <img src="https://img.shields.io/badge/Claude-Haiku_4.5-blueviolet?logo=anthropic" />
  <img src="https://img.shields.io/badge/OpenAI-Whisper_%7C_TTS-green?logo=openai" />
</p>

# Samantha — Your Personal AI in the Menu Bar

A macOS menu bar AI assistant inspired by the movie *Her*. Built with SwiftUI and Vibe Coding in a weekend.

Samantha lives in your menu bar, understands your context through your blog posts (RAG), talks to you with voice (STT/TTS), controls your Mac via shell commands, and **proactively watches over you** with suggestions.

## Features

### Core Chat
- Menu bar resident app (no Dock icon) via `MenuBarExtra`
- Chat UI with Claude API (Haiku 4.5) — empathetic, context-aware responses
- Full conversation history within each session

### RAG (Retrieval-Augmented Generation)
- Loads your blog posts (Markdown) from the `BlogData/` folder
- Embeds them via OpenAI `text-embedding-3-small`
- Cosine similarity search — top 3 relevant articles injected into context
- Samantha answers with knowledge of *your* writing

### Voice Conversation
- **Speech-to-Text**: Record via mic button → OpenAI Whisper transcription
- **Text-to-Speech**: Every AI response is read aloud (OpenAI TTS, `nova` voice)
- Feels like actually talking to Samantha

### Mac Control (Function Calling / Tool Use)
- Claude decides when to run shell commands via `execute_shell_command` tool
- Controls apps via AppleScript (`osascript`): Spotify, Finder, PowerPoint, etc.
- Checks disk space, battery, system status — anything you can do in Terminal
- Deadlock-free async execution with 10-second timeout

### Proactive AI (Background Monitoring)
- **Every 5 minutes**, Samantha silently checks your Mac's state:
  - Time of day, battery level, running apps, uptime
  - Your recent conversation history (last 24 hours)
- **Change detection**: Only calls the API when context actually changes (saves cost)
- **Smart suggestions** via macOS notifications:
  - "You've been working for 3 hours — take a break?"
  - "Battery at 12% — plug in your charger"
  - "It's past midnight — get some rest"
- **30-minute cooldown** between suggestions to avoid being annoying
- Suggestion banner appears inside the chat window

### Activity Logging
- All conversations and tool executions logged to `~/.samantha/activity_log.json`
- Auto-cleanup: entries older than 7 days are removed on launch
- Feeds into proactive analysis for pattern recognition

## Architecture

```
SamanthaApp.swift          → MenuBarExtra + AppDelegate (notifications)
ContentView.swift          → Chat UI + mic button + suggestion banner
ChatService.swift          → Claude API + Tool Use loop + shell execution
AudioService.swift         → OpenAI Whisper (STT) + TTS (nova)
RAGService.swift           → Blog embedding + cosine similarity search
ProactiveService.swift     → Background monitor + Claude analysis + notifications
ActivityLogger.swift       → JSON activity log + summarization
```

## Setup

### 1. Get your API keys
- **Anthropic Claude API key**: https://console.anthropic.com → API Keys → Create Key
- **OpenAI API key** (for Whisper STT + TTS): https://platform.openai.com/api-keys

### 2. Clone & configure
1. Clone the repo
2. Copy `Config.xcconfig.sample` to `Config.xcconfig`
3. Fill in your API keys:
   ```
   ANTHROPIC_API_KEY = sk-ant-...
   OPENAI_API_KEY = sk-proj-...
   ```
   ⚠️ `Config.xcconfig` is already in `.gitignore` — never commit it.

### 3. Open in Xcode
4. Open `Samantha.xcodeproj` in Xcode
5. Build & Run (Cmd+R)
6. Look for the ✨ icon in your menu bar

### ⚠️ Important: App Sandbox is disabled

Samantha runs **outside the macOS App Sandbox** by design. This is required because the app:
- Executes arbitrary shell commands via Claude's tool use (`execute_shell_command`)
- Controls other apps via AppleScript (`osascript`)
- Reads system state (running apps, battery, uptime) for proactive monitoring

The `Samantha.entitlements` file is intentionally empty (`<dict/>`) and **App Sandbox** under *Signing & Capabilities* is turned OFF. If you re-enable the sandbox, shell execution and AppleScript control will stop working.

> Because the sandbox is off, Samantha can do anything *you* can do in Terminal. Only run it with API keys and a setup you trust.

### macOS Permissions

On first launch, macOS will prompt for:
- **Microphone access** — required for voice chat (Whisper STT). Grant via *System Settings → Privacy & Security → Microphone*.
- **Notifications** — required for proactive suggestions. Grant via *System Settings → Notifications → Samantha*.

Some shell/AppleScript actions may also trigger **Automation** prompts (e.g. controlling Spotify or Finder). Allow them when asked.

## API Cost

| Feature | Model | Est. Daily Cost |
|---------|-------|-----------------|
| Chat | Claude Haiku 4.5 | ~$0.01-0.05 |
| RAG Embeddings | text-embedding-3-small | ~$0.001 |
| Proactive Checks | Claude Haiku 4.5 | ~$0.02 |
| Voice (STT) | Whisper | ~$0.01 |
| Voice (TTS) | tts-1 nova | ~$0.03 |
| **Total** | | **~$0.07-0.11/day** |

## Blog Post

Read the story behind building Samantha:
[I Built My Own 'Her' Samantha Over a Weekend](https://yuichi.blog/blog/her-samantha-vibe-coding)

## License

MIT

---

*Built with Vibe Coding by [Yuichi](https://yuichi.blog) — a medical student in Bulgaria who codes on weekends.*
