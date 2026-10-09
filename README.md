<div align="center">

<img src="docs/images/icon.png" width="128" alt="Saywrite icon">

# Saywrite

**Tap a key. Speak. Your text is already there.**

Local, instant AI dictation for macOS that only lets AI touch your words when they actually need it.

**100% free. Open source. No account, no subscription, no cloud.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Price: free](https://img.shields.io/badge/price-free%20forever-brightgreen)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![100% offline](https://img.shields.io/badge/offline-100%25-brightgreen)

<img src="docs/images/overlay-recording.png" width="440" alt="Saywrite recorder panel">

</div>

---

## Why Saywrite

Most dictation apps run every sentence you say through a language model. That is slow, and it rewrites text that was fine to begin with. Saywrite flips that around:

- 💸 **Completely free.** No trial, no paywall, no "pro" tier, no account. Everything runs on your Mac, so there is nothing to pay for.
- ⚡ **Text before you blink.** Saywrite transcribes and cleans up *while you are still talking*. When you tap the key to stop, the work is basically done: typically **about a quarter of a second from stop to text**, including AI corrections.
- 🎯 **AI only where it is needed.** Every dictation gets instant, deterministic cleanup: filler words, stutters, capitalization, punctuation and spoken commands. The language model only sees the **sentence** that needs it (plus the one before, when you correct yourself across a pause). Everything else stays exactly as you said it.
- 👀 **You always know what changed.** After every dictation the panel shows a summary like `2 filler words · AI: 1 correction`, and one click on **↩ Original** swaps in the version without AI.
- 🔒 **Private by design.** Speech recognition runs on the Apple Neural Engine and the language model runs locally through Ollama. With the default Ollama address nothing leaves your Mac, and there is no telemetry. If you point Saywrite at an Ollama server elsewhere, the settings warn you that your dictations go there.
- 🪶 **Light on memory.** Built for an 8 GB MacBook. The speech model lives on the Neural Engine, and the LLM is loaded when you start dictating and released after 15 idle minutes.
- 🌍 **English and German**, with automatic language detection. The speech model understands 25 European languages.

<div align="center">
<img src="docs/images/overlay-done.png" width="440" alt="After inserting: summary of changes and Original button">
</div>

## Features

| | |
|---|---|
| **Tap or hold** | Tap right ⌥ to start, tap again to insert. Or hold it and release. **Esc** cancels. A soft sound marks start and stop. |
| **Self-corrections** | "I'll be there at 5, no, at 6" → *I'll be there at 6.* "We could order pizza. Actually, scratch that, let's cook." → *Let's cook.* This also works across a pause. |
| **Rewrite by voice** | Select text, tap right ⌘ and say "more formal", "shorter" or "in German". |
| **Style per app** | Casual in Messages, WhatsApp and Slack (no period after a single sentence), formal in Mail and Word ("gonna" → "going to"), neutral everywhere else. Fully configurable. |
| **Dictionary** | Names and terms are always written your way ("git hub" → "GitHub"). Applied as a rule, never guessed. |
| **Spoken commands** | comma, question mark, exclamation mark, colon, semicolon, open/close quote, open/close paren, new line, new paragraph. The German equivalents work too. |
| **Knows what to leave alone** | "The comma is missing", "a new line of credit", "I think that that is right", e-mail addresses, URLs and abbreviations like "e.g." stay exactly as spoken. |
| **Safe AI** | A guard rejects model output that answers your question instead of transcribing it, invents text, or loses a number you corrected to. You then get the rule-cleaned version. Rewrites are checked too: a chat preamble is stripped, and an essay or an echoed instruction leaves your text unchanged. If Ollama times out once, the rest of that dictation goes without AI instead of waiting again for every sentence. |
| **Never loses a word** | If Ollama is down or slow, the rules-only text is inserted. If you switch to another app while the text is being prepared, it is copied instead of landing in the wrong window. "Nothing heard" and a silent microphone are reported, and your recent dictations are kept in the history (readable by your user only). Password fields are detected: nothing is inserted there, and that dictation is not saved. |
| **Your microphone** | Pick any input device. Switching to AirPods mid-dictation is handled. |
| **Hands-free safety** | A forgotten recording stops by itself after 60 s of silence. |

## Speed and accuracy

Measured with the real models, on a MacBook with 8 GB RAM.

**Latency** (`scripts/bench.sh`, time from the end of speech to finished text; the app records 0.15 s longer so the last syllable is never cut off):

| Dictation | Rules only | With AI self-correction |
|---|---|---|
| Short sentence (1.6 s) | 0.10 s | – |
| Two sentences with a correction (8 s) | – | 0.24 s |
| Four sentences with pauses (17 s) | 0.09–0.13 s | – |

**Text quality** (`make eval`, realistic recognizer output typed into the eval sets and run through the full pipeline with the local LLM; the speech model itself is not part of this measurement):

| Test set | Cases | Exactly right |
|---|---|---|
| English | 130 | ~90 % |
| German | 107 | ~90 % |

The sets cover everyday messages, e-mails, self-corrections of many shapes, sentences that must not change, numbers, dates, URLs, math, spoken commands and all three styles.

Take these numbers as a development benchmark, not an independent result: the rules and prompts were tuned while these sets were written, so they flatter the pipeline. For an honest number, add cases from real dictations to a separate file (for example `Tests/Eval/holdout.json`) and never adjust rules against it. `--report Tests/Eval/results.jsonl` appends each run (date, set, model, result) so changes show up over time.

## How it works

```mermaid
flowchart LR
    K[Tap key] --> R[Record]
    K -. prime .-> L[(Local LLM)]
    R --> V{Pause detected}
    V -->|each utterance| P[Parakeet<br/>Neural Engine]
    P --> C[Rules<br/>fillers · punctuation · commands]
    C --> G{Needs AI?}
    G -->|no| J[Join in order]
    G -->|one sentence| L
    L --> Q[Output guard]
    Q --> J
    J --> D[Dictionary] --> I[Paste once]
```

1. **Tapping the key** starts recording, and as soon as it is clear you are dictating (not typing a ⌥ shortcut), the language model is primed in the background, so there is no cold start later.
2. **A voice-activity detector** (Silero) cuts your speech at natural pauses. **Parakeet Ultra** transcribes each piece on the Neural Engine right away, while you keep talking.
3. **The language is detected** from the recognized words (English or German), and **deterministic rules** for that language clean every piece instantly.
4. **A gate** decides per sentence whether the model is needed at all. Most sentences never reach it.
5. **An output guard** checks what the model returns: mostly your own words, a plausible length, and the corrected values still present. Anything else is thrown away.
6. **The text is joined and pasted once**, so your cursor doesn't jump around, and your clipboard is restored afterwards (except for very large or lazily provided clipboard contents, which then stay replaced by the dictation). Without a text field in front, or when another app came to the front meanwhile, the text is copied instead.

## Install

**Requirements:** macOS 14+ on Apple Silicon.

### Download (no Xcode needed)

1. Download `Saywrite-vX.Y.Z.zip` from the [latest release](https://github.com/ursalfas11/saywrite/releases/latest) and unzip it.
2. Move `Saywrite.app` to `/Applications`.
3. Open it. Saywrite is signed ad hoc, not notarized by Apple, so macOS blocks the first launch. Either right-click the app → **Open** → **Open**, or run once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Saywrite.app
   ```

Each release lists the SHA-256 of the zip next to it.

### Build from source

Needs Xcode 16+ (the Command Line Tools alone cannot build the SwiftUI app).

```bash
git clone https://github.com/ursalfas11/saywrite.git
cd saywrite
make install                    # builds and copies Saywrite.app to /Applications
open /Applications/Saywrite.app
```

**Optional but recommended**, for AI self-corrections and rewriting:

```bash
brew install ollama && brew services start ollama
ollama pull qwen2.5:3b
```

On first launch Saywrite asks for **Microphone** and **Accessibility** access. Accessibility is needed for the global key and for pasting. The speech model (~600 MB) is then downloaded once. Without Ollama, Saywrite works with rule-based cleanup only.

## Usage

| Action | How |
|---|---|
| Dictate | Tap **right ⌥**, speak, tap again (or hold and release) |
| Stop | Tap again, or click the red button in the panel |
| Cancel | **Esc** |
| Undo the AI | Click **↩ Original** right after inserting (offered in text fields where undo is reliable) |
| Rewrite a selection | Select text, tap **right ⌘**, speak the instruction, tap again |
| Paste the last dictation | Menu bar icon → *Paste last dictation* |

Everything else is in the menu bar icon → **Settings**: keys, microphone, language, models, styles per app, dictionary and history. The interface, including the permission prompts, follows your system language (English or German).

## Configuration tips

- **Bigger model for rewriting:** choose, for example, `qwen2.5:7b` under *Model (rewrite)* if you have the RAM. Dictation cleanup stays on the small, fast model.
- **Less AI in an app:** set that app to *Casual*, which uses AI only for explicit self-corrections, or switch AI off entirely in the menu.
- **Debugging:** `open --env SAYWRITE_DEBUG=1 --stderr /tmp/saywrite.log /Applications/Saywrite.app` logs hotkeys, pause detection and every model call. The log contains your dictated text, so delete it when you are done.

## Development

```bash
make test                   # unit tests for the text pipeline
make eval                   # quality evaluation with the real local LLM (German set)
swift run -c release SaywriteEval Tests/Eval/cases.json --model qwen2.5:7b --report Tests/Eval/results.jsonl
swift run -c release SaywriteEval Tests/Eval/cases-en.json   # English set
make run                    # build the .app and launch it
scripts/bench.sh            # latency benchmark with the real models, no microphone needed
```

| Path | What lives there |
|---|---|
| `Sources/SaywriteCore` | Platform-independent logic: language detection, rules, gate, sentence splitter, dictionary, change summary, Ollama client and output guards, dictation session, the tap-or-hold hotkey logic and the paste-target rules. Fully unit-tested. |
| `Sources/Saywrite` | The macOS app: event tap, audio capture, VAD segmentation, Parakeet, text insertion (Accessibility queries run off the main thread, which also serves the event tap), recorder panel, sounds, settings. Not unit-tested; CI builds it. |
| `Sources/SaywriteEval` | The quality evaluation runner. Cases live in `Tests/Eval`. |
| `docs/superpowers/specs` | The design document and the decisions made while building it. |

Useful hidden flags:
- `Saywrite --selftest <wav> [casual|neutral|formal] [--no-ai]` runs a recording through the full pipeline.
- `Saywrite --render-overlay <dir>` renders the panel states to PNG.

## Roadmap

- Signed and notarized release builds with auto-update
- Matching the spacing and capitalization of the text around the cursor
- Numbered lists and e-mail addresses by voice
- Learning dictionary entries from your corrections

Contributions are welcome, especially new eval cases for more languages. Please open an issue first for bigger changes.

## Credits and license

Saywrite is **MIT licensed**, see [LICENSE](LICENSE). You can use, change and share it for free, including commercially. It was written from scratch and builds on these open projects:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0): Core ML speech recognition and voice-activity detection
- [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) (CC BY 4.0): the speech model
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT)
- [Ollama](https://ollama.com) and [Qwen 2.5](https://huggingface.co/Qwen): the local language model

The full notices are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
