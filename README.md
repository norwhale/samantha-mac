<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.0+-black?logo=apple" />
  <img src="https://img.shields.io/badge/Swift-5.0-orange?logo=swift" />
  <img src="https://img.shields.io/badge/Claude-Haiku_4.5-blueviolet?logo=anthropic" />
  <img src="https://img.shields.io/badge/OpenAI-Whisper_%7C_TTS-green?logo=openai" />
  <img src="https://img.shields.io/badge/Ollama-Gemma_4_31B-lightgrey?logo=ollama" />
</p>

# Samantha — Your Personal AI in the Menu Bar

A macOS menu bar AI assistant inspired by the movie *Her*. Built with SwiftUI and Vibe Coding over a weekend.

Samantha lives in your menu bar, **understands your context** through your blog posts (RAG), **talks with you** via voice (STT/TTS), **controls your Mac** through shell + AppleScript, **reads your Gmail and Calendar**, **runs multiple specialist agents in parallel**, and **proactively watches over you** with smart suggestions.

---

## Features

Samantha is organized into seven feature groups. Each can be used independently from chat — Claude decides which tools to call based on what you ask.

### 💬 Conversation

**Core Chat**
- Menu bar resident app (no Dock icon) via `MenuBarExtra`
- Chat UI powered by Claude Haiku 4.5 — empathetic, context-aware responses
- Full conversation history within each session

**Voice Conversation**
- **Speech-to-Text**: tap the mic button → recording → OpenAI Whisper transcription
- **Text-to-Speech**: every reply is read aloud with OpenAI TTS (`nova` voice)
- Hands-free mode that feels like actually talking to Samantha

**RAG over your blog**
- Loads your Markdown blog posts from `BlogData/`
- Embeds them with OpenAI `text-embedding-3-small`
- Cosine-similarity search injects the top 3 relevant articles into context
- Samantha answers with knowledge of *your* writing — your tone, your past posts, your projects

### 🎮 Mac Control (Function Calling / Tool Use)

Claude decides when to run shell commands via the `execute_shell_command` tool. This gives Samantha **full Terminal-level access** to your Mac.

**System inspection**
```
df -h                  # disk space
pmset -g batt          # battery
uptime                 # load average
ps aux | grep ...      # running processes
```

**App control via AppleScript** (`osascript -e 'tell application "X" to ...'`)

| App | Example commands |
|---|---|
| **Spotify** | play / pause / next / previous, get current track |
| **Microsoft Word** | open documents, create new files |
| **Microsoft PowerPoint** | open decks, advance slides |
| **Microsoft Excel** | open workbooks |
| **Finder** | open folders, reveal files |
| **Safari / Chrome** | open URLs, get current tab |
| **Notes / Mail / Calendar** | open the app, create entries |
| **Any AppleScript-aware app** | works out of the box |

Async execution is deadlock-free with a 10-second per-command timeout.

### 📧 Productivity Integrations (Google OAuth 2.0)

Samantha connects to your Google account on demand and exposes Gmail + Calendar as native tools.

**Gmail tools**
- `gmail_list_unread` — list your unread inbox (subject, sender, time)
- `gmail_read_message` — fetch the body of a specific message
- `gmail_search` — Gmail-style search queries (`from:`, `subject:`, `newer_than:1d`, etc.)

**Google Calendar tools**
- `calendar_today` — what's on today
- `calendar_list_upcoming` — next N days of events
- `calendar_search` — keyword search across events
- `calendar_create_event` — create a new event with title, start/end (ISO 8601), description, location

OAuth tokens are stored locally at `~/.samantha/gmail_tokens.json` and refreshed automatically.

### 🧠 Multi-Agent Orchestration

Samantha can spin up **multiple specialist Claude agents in parallel** and synthesize their outputs.

- **`multi_agent_analyze`** — runs N specialist roles in parallel (e.g. *medical expert*, *economic analyst*, *cultural anthropologist*) and merges their perspectives into one coherent answer.
- **`multi_agent_plan_execute`** — first plans a multi-step task, then executes each step in order, then synthesizes the result. Useful for complex requests like *"research X, summarize, and draft an email about it."*

Each specialist runs as its own Claude API call via Swift `TaskGroup`, so latency stays close to the slowest single agent rather than the sum.

### 🛰 Proactive AI (Background Monitoring)

Samantha doesn't just respond — she watches.

- **Every 5 minutes**, she silently checks your Mac:
  - Time of day, battery level, running apps, uptime
  - Recent conversation history (last 24 hours)
- **Change detection**: only calls the API when context actually changes (saves cost)
- **Smart suggestions** delivered as native macOS notifications:
  - *"You've been working for 3 hours — take a break?"*
  - *"Battery at 12% — plug in your charger"*
  - *"It's past midnight — get some rest"*
- **30-minute cooldown** between suggestions so she's never annoying
- A suggestion banner also appears inside the chat window

### 📈 Cognitive Load Monitor (BCI-Ready)

A separate background service estimates your cognitive load on a 0–10 scale from system signals:

- CPU pressure / system load
- Number of running apps
- Currently focused app weight
- Circadian factor (time of day)
- Consecutive uptime days
- Recent conversation frequency

It's designed around a `LoadSource` protocol, so the system signals can be **swapped for an EEG / BCI device** later without changing the UI. Live history is plotted in the Command Center.

### 🏠 Local-First Mode (Optional)

Samantha can use **Ollama** running `gemma4:31b` locally as the orchestrator brain instead of Claude.

- Auto-detects Ollama at `http://localhost:11434`
- Used for high-level routing/synthesis when you want to keep data local
- Cloud Claude agents are still called for specialist tasks unless disabled

Install Ollama and pull the model:
```bash
brew install ollama
ollama pull gemma4:31b
```

### 🖥 Command Center (Full Window UI)

Beyond the menu bar popover, Samantha ships a standalone **Command Center** window:

- Live cognitive-load chart (Swift Charts)
- Multi-agent status panel
- System context panel (battery, uptime, focused app, etc.)
- Larger chat surface for long sessions
- High-DPI tuned (5K2K friendly)

Open it from the menu bar icon → *Open Command Center*.

### 📝 Activity Logging

- All conversations and tool executions logged to `~/.samantha/activity_log.json`
- Auto-cleanup: entries older than 7 days are removed on launch
- Feeds into proactive analysis and pattern recognition

---

## Architecture

```
SamanthaApp.swift          → MenuBarExtra + AppDelegate (notifications)
ContentView.swift          → Menu-bar chat UI + mic button + suggestion banner
CommandCenterView.swift    → Standalone full-window UI (charts, panels)
WindowManager.swift        → Manages the Command Center NSWindow

ChatService.swift          → Claude API + Tool Use loop + shell execution
AudioService.swift         → OpenAI Whisper (STT) + TTS (nova)
RAGService.swift           → Blog embedding + cosine similarity search

GmailService.swift         → Gmail API + OAuth 2.0 token management
CalendarService.swift      → Google Calendar API
MultiAgentService.swift    → Parallel specialist agents + synthesis
OllamaService.swift        → Local Gemma 4 31B orchestrator (optional)

ProactiveService.swift     → Background monitor + Claude analysis + notifications
CognitiveLoadService.swift → 0–10 load estimator (BCI-ready)
ActivityLogger.swift       → JSON activity log + summarization
```

---

## Setup

### 1. Get your API keys

Required:
- **Anthropic Claude API key**: https://console.anthropic.com → API Keys → Create Key
- **OpenAI API key** (Whisper STT + TTS + embeddings): https://platform.openai.com/api-keys

Optional (only if you want Gmail / Calendar):
- **Google OAuth 2.0 client**: https://console.cloud.google.com → APIs & Services → Credentials → Create OAuth Client ID (Desktop app). Enable the **Gmail API** and **Google Calendar API** for your project. Add `http://localhost:8089/callback` as an authorized redirect URI.

### 2. Clone & configure

1. Clone the repo
2. Copy `Config.xcconfig.sample` to `Config.xcconfig`
3. Fill in your API keys:
   ```
   ANTHROPIC_API_KEY = sk-ant-...
   OPENAI_API_KEY    = sk-proj-...
   GOOGLE_CLIENT_ID     = ...   # optional, for Gmail/Calendar
   GOOGLE_CLIENT_SECRET = ...   # optional, for Gmail/Calendar
   ```
   ⚠️ `Config.xcconfig` is already in `.gitignore` — never commit it.

### 3. Open in Xcode

4. Open `Samantha.xcodeproj` in Xcode
5. Build & Run (Cmd+R)
6. Look for the ✨ icon in your menu bar

### 4. (Optional) Local mode

If you want Samantha to use a local model as the orchestrator brain:
```bash
brew install ollama
ollama pull gemma4:31b
ollama serve   # usually runs automatically
```
Samantha will detect it on startup.

### ⚠️ Important: App Sandbox is disabled

Samantha runs **outside the macOS App Sandbox** by design. This is required because the app:
- Executes arbitrary shell commands via Claude's tool use (`execute_shell_command`)
- Controls other apps via AppleScript (`osascript`)
- Reads system state (running apps, battery, uptime) for proactive monitoring
- Talks to a local Ollama server (optional)

The `Samantha.entitlements` file is intentionally empty (`<dict/>`) and **App Sandbox** under *Signing & Capabilities* is turned OFF. If you re-enable the sandbox, shell execution and AppleScript control will stop working.

> Because the sandbox is off, Samantha can do anything *you* can do in Terminal. Only run it with API keys and a setup you trust.

### macOS Permissions

On first launch, macOS will prompt for:
- **Microphone access** — required for voice chat (Whisper STT). Grant via *System Settings → Privacy & Security → Microphone*.
- **Notifications** — required for proactive suggestions. Grant via *System Settings → Notifications → Samantha*.

Some shell/AppleScript actions may also trigger **Automation** prompts (e.g. controlling Spotify or Finder). Allow them when asked.

If you use Gmail/Calendar, the first call will open a browser window for **Google OAuth consent**.

---

## API Cost

Rough estimate for personal daily use. Gmail and Calendar APIs are free at this scale. Ollama is free (runs locally).

| Feature | Model | Est. Daily Cost |
|---------|-------|-----------------|
| Chat | Claude Haiku 4.5 | ~$0.01–0.05 |
| RAG Embeddings | text-embedding-3-small | ~$0.001 |
| Proactive Checks | Claude Haiku 4.5 | ~$0.02 |
| Multi-agent (occasional) | Claude Haiku 4.5 × N | ~$0.01–0.05 |
| Voice (STT) | Whisper | ~$0.01 |
| Voice (TTS) | tts-1 nova | ~$0.03 |
| Gmail / Calendar | Google APIs | Free |
| Local orchestration | Ollama / Gemma 4 31B | Free |
| **Total** | | **~$0.08–0.16 / day** |

---

## Blog Post

Read the story behind building Samantha:
- [I Built My Own 'Her' Samantha Over a Weekend](https://yuichi.blog/blog/her-samantha-vibe-coding)
- [Teaching Samantha to Think Ahead — Adding Proactive AI](https://yuichi.blog/blog/samantha-proactive-ai)

---

## License

MIT

---

*Built with Vibe Coding by [Yuichi](https://yuichi.blog) — a medical student in Bulgaria who codes on weekends.*
