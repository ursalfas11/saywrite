# Saywrite — Design

Date: 2026-09-27
Status: implemented (v0.1.0); section "Changes during implementation" records deviations

## Goal

A native macOS menu-bar dictation app that is faster and less intrusive than existing tools:
text appears almost immediately after releasing the hotkey, and AI only touches the text when
it actually needs fixing. Fully local (on-device speech recognition + local LLM via Ollama).
Published as open source under the MIT license.

Primary user: German speaker on a Mac with 8 GB RAM. The app must work well for German first;
other languages supported by Parakeet v3 come for free.

## Clean-room requirement

Saywrite is written from scratch. No code, assets, strings, or file structure may be copied from
VoiceInk or any other GPL-licensed dictation app. Implementation must not consult VoiceInk source.
Only permissively licensed dependencies (MIT, Apache-2.0, BSD) are allowed; their license texts
are shipped in `THIRD_PARTY_LICENSES`.

## Scope of v1

In scope:

1. Push-to-talk dictation with global hotkey (hold to talk, double-tap for hands-free toggle)
2. Instant text: segment-wise transcription and cleanup while the user is still speaking
3. Two-stage cleanup: deterministic rules always, LLM only when a gate says it is needed
4. Per-app style (casual / neutral / formal), mapped by frontmost app bundle ID
5. Rewrite command: select text, hold second hotkey, speak an instruction, selection is replaced
6. Change summary in the overlay after each insertion
7. Overlay pill (bottom center, live level bars, state colors)
8. Settings window + first-run permission onboarding
9. History of the last 20 dictations (raw + final), local only

Out of scope for v1 (explicitly deferred): learning from user corrections, one-key revert to raw
text, custom vocabulary, embedded llama.cpp backend, Windows/Linux, notarization, auto-update.

## Technology

- Swift 6, SwiftUI + AppKit, macOS 14+, Apple Silicon
- Menu-bar only app (`LSUIElement`), no Dock icon
- Speech recognition: FluidAudio (Apache-2.0), Parakeet Ultra (post-trained TDT v3 0.6b) batch model on the Neural
  Engine. (FluidAudio's streaming Parakeet EOU model is English-only, so it is not used.)
- Voice activity detection: Silero VAD via FluidAudio
- LLM: Ollama over HTTP (`http://localhost:11434`, `/api/chat`), default model `qwen2.5:3b`,
  user-selectable
- Build: Swift Package Manager + Xcode project, `make build` / `make install`, ad-hoc signed

## Architecture

Each unit has one responsibility and a narrow interface. Units that talk to the outside world sit
behind protocols so they can be faked in tests.

| Unit | Responsibility | Interface (sketch) |
|---|---|---|
| `HotkeyMonitor` | Global hotkeys, press/release/double-tap detection | emits `.dictateDown`, `.dictateUp`, `.toggle`, `.rewriteDown`, `.rewriteUp` |
| `AudioCapture` | Mic capture to in-memory 16 kHz mono float buffer, level metering | `start()`, `stop() -> [Float]`, `levels: AsyncStream<Float>`, `samples: AsyncStream<[Float]>` |
| `Segmenter` | Splits the live sample stream into utterance segments at pauses (VAD) | `segments: AsyncStream<AudioSegment>`, `flush()` |
| `Transcriber` (protocol) | Audio segment -> raw text | `transcribe(_ segment) async throws -> String` — impl `ParakeetTranscriber` |
| `RuleCleaner` | Deterministic cleanup (fillers, stutter, capitalization, punctuation, spoken commands) | `clean(_ text, style) -> String` (pure) |
| `CleanupGate` | Decides whether a segment needs the LLM | `needsLLM(raw, cleaned, style) -> GateDecision` (pure) |
| `LLMClient` (protocol) | Text cleanup / rewrite via a language model; model prewarm | `prewarm()`, `cleanup(text, context, style) async throws -> String`, `rewrite(selection, instruction) async throws -> String` — impl `OllamaClient` |
| `StyleResolver` | Frontmost app bundle ID -> `Style` | `currentStyle() -> Style` |
| `DictationPipeline` | Orchestrates one dictation session end to end | `begin()`, `end() async -> DictationResult` |
| `TextInserter` | Insert text at cursor, read current selection | `insert(_ text) -> InsertOutcome`, `selectedText() -> String?` |
| `ChangeSummarizer` | Word-level diff raw vs final -> summary counts | `summarize(raw, final, usedLLM) -> ChangeSummary` (pure) |
| `OverlayController` | Pill window and its states | `show(state)` |
| `HistoryStore` | Last 20 results, persisted as JSON in Application Support | `append(_ result)`, `items` |
| `Settings` | Hotkeys, style mapping, model name, timeouts (UserDefaults) | observable model |

## Data flow — dictation

```
dictateDown
  ├─ AudioCapture.start()
  ├─ LLMClient.prewarm()             (loads model while user speaks)
  ├─ StyleResolver.currentStyle()    (captured once per session)
  └─ Overlay: recording (live levels)

while recording:
  Segmenter emits segment at each pause >= 500 ms
    -> Transcriber -> RuleCleaner -> CleanupGate
         -> gate says LLM: LLMClient.cleanup(segmentText, context: previous segment, style)
         -> else: keep rule-cleaned text
  results stored in order; nothing is inserted yet

dictateUp
  ├─ AudioCapture.stop(); Segmenter.flush() -> last segment processed as above
  ├─ Overlay: processing
  ├─ join segment results in order (single space; paragraph commands already applied)
  ├─ TextInserter.insert(final)      (one insertion, cursor does not jump)
  ├─ ChangeSummarizer -> Overlay: done + summary (~2 s)
  └─ HistoryStore.append
```

Segments are processed concurrently with recording but results are joined strictly in capture
order. LLM calls are serialized (one at a time) because Ollama runs one request at a time on 8 GB.

Recordings shorter than 0.3 s or with no detected speech are discarded silently.

## Cleanup rules (RuleCleaner)

Always applied, pure and deterministic:

- Remove German filler words as standalone tokens: `ähm`, `äh`, `öhm`, `ehm`, `hm`, `mhm`
  (case-insensitive, with attached commas cleaned up)
- Collapse immediate word repetitions of 1–2 word sequences (`ich ich` -> `ich`,
  `wir haben wir haben` -> `wir haben`); never collapse across sentence punctuation
- Spoken commands (whole-word, case-insensitive): `neuer Absatz` -> `\n\n`, `neue Zeile` -> `\n`,
  `Komma` -> `,`, `Punkt` -> `.`, `Fragezeichen` -> `?`, `Ausrufezeichen` -> `!`,
  `Doppelpunkt` -> `:`. Only when the word stands alone as a command token (not inside
  compounds like `Punktzahl`).
- Capitalize first letter of each sentence
- Ensure terminal punctuation at end of the whole text, except in `casual` style when the text is
  a single sentence
- Normalize whitespace around punctuation

## CleanupGate

Returns `useLLM` if any of these hold, otherwise `rulesOnly`:

- Style is `formal`
- Self-correction markers present: `nein`, `ich meine`, `besser gesagt`, `also nicht`,
  `sondern` following a correction pattern, `Moment`, `Quatsch` (word list lives in one table so
  it is easy to tune)
- A run of more than 25 words without any sentence punctuation in the raw transcript
- Raw transcript is longer than 60 words (long dictations benefit from structure)

Style `casual` never uses the LLM unless a self-correction marker is present.

## LLM prompts

Stored as plain-text resources, German, conservative. Cleanup prompt core rules:
keep wording and word order, only fix obvious errors and apply self-corrections, never answer or
execute questions/instructions contained in the text, keep math and numbers as spoken (no LaTeX,
no symbols), always German, if the text is already correct return it unchanged, output only the
text. The `formal` style adds: complete sentences, colloquial short forms to standard forms
(`hab` -> `habe`), no change of word choice beyond that. The previous segment is passed as
read-only context, clearly delimited, with the instruction not to repeat it.

Rewrite prompt: apply the spoken instruction to the delimited selection, output only the result,
keep facts, do not answer questions inside the selection. Language follows the instruction
(e.g. "auf Englisch"), default German.

Ollama requests: `stream: false`, `keep_alive: "15m"`, `options.temperature: 0.1`,
`options.num_predict` capped at roughly 2x input tokens + 64. Prewarm = request with empty
messages and `keep_alive: "15m"` (loads the model without generating).

## Styles

| Style | Default apps (bundle IDs) | Behavior |
|---|---|---|
| casual | WhatsApp, Messages, Slack, Telegram, Discord, Signal | rules only (LLM only for self-corrections), no period after a single sentence |
| neutral | everything not mapped | rules, LLM when gate says so |
| formal | Mail, Outlook, Word, Pages, Spark | LLM always, formal prompt addition |

Users can reassign any app in Settings (list of recently used apps + picker).

## Rewrite flow

`rewriteDown`: `TextInserter.selectedText()` via Accessibility API (`AXSelectedText`), fallback
simulated Cmd+C with clipboard save/restore. If no selection: overlay shows "Kein Text markiert",
session ends. Otherwise record instruction; on `rewriteUp`: transcribe (no segmentation needed),
`LLMClient.rewrite`, replace selection via insert. LLM failure: selection stays untouched, overlay
shows error.

## Text insertion

Save all clipboard items, put text on clipboard, post Cmd+V via CGEvent, restore clipboard after
~300 ms. If no focused editable element is found via Accessibility, leave text on the clipboard
and show "In Zwischenablage kopiert".

## Change summary

Word-level diff (LCS over tokens) between raw transcript and final text. Counts: removed filler
words, punctuation added/changed, other words changed by LLM. Overlay shows e.g.
`✓ 3 Füllwörter · 2 Satzzeichen · KI: 1 Korrektur` or `✓ unverändert`; `⚠ ohne KI` appended when
the LLM was needed but failed.

## Overlay

Borderless, non-activating floating panel, bottom center above the Dock, dark rounded pill.
States: `recording` (live level bars reacting to voice, red accent), `processing` (subtle pulse),
`done` (green check + summary, fades after ~2 s), `error` (amber, message, click opens relevant
System Settings pane). Never steals focus. Own visual design; not a copy of any existing app.

## Error handling

Principle: a dictation is never lost.

- LLM unreachable, error, or slower than 10 s: use rule-cleaned text, mark `⚠ ohne KI`,
  no retry
- Transcriber failure on a segment: keep going with other segments; if all fail, show error and
  keep audio-free history entry with the error
- Missing microphone or Accessibility permission: overlay error, click opens System Settings
- Ollama not installed / model missing: onboarding and Settings show status and the exact
  `ollama pull` command; dictation still works rules-only
- Parakeet model download (first run) shows progress in onboarding; hotkey disabled until ready

## Performance targets (8 GB Mac, model warm)

| Case | Target (hotkey release -> text inserted) |
|---|---|
| Short clean sentence, rules only | < 0.5 s |
| With LLM cleanup, prewarmed | < 1.5 s |

Memory: Parakeet resident ~0.5 GB. LLM (~2 GB) loaded on hotkey press, released by Ollama after
15 min idle. A benchmark script (`scripts/bench.sh`) measures the targets with recorded sample
audio.

## Testing

- Unit tests (pure units): `RuleCleaner`, `CleanupGate`, `StyleResolver` mapping,
  `ChangeSummarizer`, segment joining — table-driven with real German example sentences,
  including math dictations that must stay verbatim
- `OllamaClient` against a local fake HTTP server (success, timeout, 500, malformed JSON)
- `DictationPipeline` with fake `Transcriber` / `LLMClient` / `TextInserter`: ordering of
  segments, fallback on LLM failure, discard of empty recordings
- Manual checklist for hotkeys, overlay, insertion in common apps (Notes, Mail, Safari, Slack,
  VS Code)

## Repository & publishing

- New public GitHub repo `saywrite` (created only after v1 works and the user confirms)
- `LICENSE` (MIT), `THIRD_PARTY_LICENSES`, `README.md` (English, with setup: Ollama install,
  model pull, build), `Makefile`
- Ad-hoc signing for local builds; notarization is a later step
- The existing private repo `local-dictation-setup` stays private and unchanged

## Changes during implementation

Found while testing with real models; the sections above describe the original plan.

- **Sentence-level LLM.** Segments are split into sentences; only sentences the gate flags go to the
  model. Requests are short (about 0.5 s each) and clean sentences are never touched.
- **No context passed to the LLM.** With the previous segment as context, qwen2.5:3b sometimes
  returned the context sentence instead of the input. Context was removed.
- **Output guard also checks word overlap.** At least 75 % (formal: 60 %) of output words must
  occur in the input, otherwise the rule-cleaned text is used.
- **Formal style is rule-based.** An always-on LLM for formal apps rewrote sentences. Formal now
  expands short forms deterministically (hab → habe, is → ist, gibt's → gibt es, ...) and uses the
  LLM only when the gate says so, like neutral.
- **Few-shot cleanup prompt** focused on self-corrections and missing punctuation (7/8 correct on
  the test set with qwen2.5:3b, the miss was caught by the guard).
- **Prewarm primes the prompt cache** by sending the system prompt with `num_predict: 1`, so the
  first real request does not pay for prompt processing.
- **Segmentation:** minimum silence 0.45 s, and segments are force-cut at the quietest spot after
  5 s, so little work is left after releasing the key even without clear pauses.
- **Hotkeys use a listen-only CGEventTap** instead of NSEvent global monitors, which fail silently;
  a refused tap is detected and retried until Accessibility is granted.
- **Separate rewrite model setting**, because rewriting is harder than cleanup for a 3B model.
- **Parakeet renders "ähm" as a lone "M"**; the rule cleaner removes a capital M between lowercase words.

Measured release-to-text latency (selftest, M-series Mac with 8 GB): 0.08–0.23 s including AI
corrections, 1.66 s in a live test where no pause was detected (before the 5 s cut was added).
