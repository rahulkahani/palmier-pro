# Palmier Pro Fork — Architecture & Modification Plan

Goal: a fork of [palmier-io/palmier-pro](https://github.com/palmier-io/palmier-pro) that (a) runs on local AI (Ollama / Core ML / Apple frameworks) instead of or alongside the paid cloud, (b) has a more powerful MCP surface, and (c) does **smart horizontal ↔ vertical conversion** — AI-driven reframing, auto-zoom on important screen content, and dynamic layout changes (PiP → top/bottom split).

Everything below is grounded in the actual codebase (cloned and inspected at the current `main`, ~287 Swift files).

---

## 1. Current architecture of Palmier Pro

Swift 6.2 SPM package (no Xcode project — `swift build` / `swift run`), SwiftUI + AppKit, AVFoundation, macOS 26 (Tahoe), Apple Silicon only, non-sandboxed Developer ID app.

```
Sources/PalmierPro/
├── App/, Editor/, Timeline/, Preview/, Inspector/, MediaPanel/, Toolbar/   ← UI shell
├── Models/            ← Timeline.swift (clips: transform, crop, keyframe tracks for
│                         position/scale/rotation/crop/opacity/volume),
│                         VideoLayout.swift (named layout templates w/ normalized slots)
├── Compositing/       ← CustomVideoCompositor (AVFoundation custom compositor),
│                         FrameRenderer, Core Image + custom Metal kernels (Metal/*.metal)
├── Export/            ← ExportService, ExportCoordinator, FCPXML/XML exporters
├── Project/           ← VideoProject, ProjectRegistry, AspectPreset (16:9, 9:16, 1:1, …)
├── Agent/
│   ├── AgentService   ← in-app chat agent
│   ├── Clients/       ← AnthropicClient (BYO API key, direct api.anthropic.com)
│   │                     PalmierClient (Convex backend v1/agent/stream — subscription)
│   ├── Tools/         ← ToolExecutor + ToolDefinitions: ~47 tools (add_clips, apply_layout,
│   │                     set_keyframes, split_clips, generate_video, search_media, …)
│   ├── MCP/           ← MCPService + MCPHTTPServer: official MCP swift-sdk, streamable
│   │                     HTTP on 127.0.0.1:19789, per-session stateful transports
│   └── Skills/        ← skill catalog readable by agents (read_skill tool)
├── Generation/        ← GenerationService/Backend → Convex RPC (generations:submit) →
│                         hosted Seedance / Kling / Nano Banana etc. (CLOSED backend)
├── Search/            ← LOCAL visual search: SigLIP 2 Core ML image+text encoders,
│                         ModelDownloader (runtime HF download, sha256 manifest),
│                         EmbeddingStore, SearchIndexCoordinator
├── Transcription/     ← LOCAL Apple SpeechTranscriber (SpeechAnalyzer) + cloud backend option
├── Account/           ← Clerk auth + Convex (only needed for cloud features)
└── Telemetry/         ← Sentry
```

**The critical design fact:** the in-app agent and the MCP server share **one tool surface** — `ToolExecutor`. `MCPService` registers the same `AgentTool` definitions the in-app chat uses. Any tool you add is instantly available to Claude Code/Desktop/Cursor via MCP *and* to the in-app agent.

**AI integration points that already exist:**
- On-device SigLIP 2 (Core ML, ANE) for semantic footage search — with a proven model-conversion pipeline (`models/siglip2/convert.py`, parity-gated at cosine ≥ 0.99) and runtime downloader.
- On-device transcription via Apple `SpeechTranscriber` (word-level timestamps power captions + `remove_words` text-based editing).
- Cloud generation (video/image/audio/upscale) through the closed Convex backend.
- No Vision framework usage yet, no Ollama/OpenAI-compatible client yet. Those are the gaps to fill.

## 2. Open source vs closed

| Component | Status |
|---|---|
| Editor, timeline, compositor, Metal kernels, export | **Open** (in repo) |
| MCP server + all ~47 tools + in-app agent chat UI | **Open** |
| Local visual search (SigLIP 2) + model conversion pipeline | **Open** |
| Local transcription (Apple Speech) | **Open** |
| In-app agent LLM via **your own Anthropic API key** | **Open** (client-side; you pay Anthropic directly) |
| In-app agent via Palmier subscription (`v1/agent/stream`) | **Closed** (Convex backend) |
| Generative AI execution (Seedance/Kling/Nano Banana jobs, upscale) | **Closed** (Convex backend `generations:submit`) |
| Cloud transcription, accounts/billing (Clerk/Convex) | **Closed** |

Consequence for the fork: you lose nothing that matters. The closed part is exclusively "submit a job to a hosted SOTA generative model." Everything needed for the vertical-conversion feature — timeline, compositor, keyframes, layouts, MCP — is open. The `generate_*` tools can be left pointing at the cloud (they still work for subscribers), routed to local backends, or hidden.

## 3. Recommended changes for strong local AI support

Three principles:

1. **Apple frameworks first for perception.** Face detection/landmarks, saliency, OCR, and human detection are solved, ANE-accelerated, zero-download problems via the **Vision framework**. Don't reach for a VLM to find a face. This keeps the app native and fast (goal #3) and makes the reframe feature deterministic and debuggable.
2. **Ollama for language/VLM reasoning, behind the existing client abstraction.** The agent already has two interchangeable clients (`AnthropicClient`, `PalmierClient`). Add a third.
3. **Local models are *providers underneath existing tools*, never a parallel path.** Tool schemas stay stable so every MCP client keeps working unchanged.

Concrete changes:

- **`LocalAI/` module** (new):
  - `ModelRegistry` — generalize `Search/Models/ModelDownloader` (HF download, sha256 manifest, versioning — the pattern is already proven for SigLIP 2) into an app-wide registry for any Core ML package.
  - `OllamaClient` — thin REST client for `localhost:11434` (chat + streaming; native API rather than the OpenAI-compat shim, so you get keep-alive and model management). Health-check/discovery so the UI can show "Ollama detected, N models".
  - `LocalAgentClient` — conforms to the same interface as `AnthropicClient`/`PalmierClient`; the in-app agent becomes fully local with e.g. Qwen 3 / Llama 3.x. Settings pane gains a provider picker: **Palmier cloud / Anthropic key / Local (Ollama)**.
- **`Analysis/` module** (new) — the perception layer (detailed in §6): Vision-based face tracking, saliency, OCR density, motion/cursor detection, shot classification, plus an `AnalysisCache` (per-asset, mirroring `TranscriptCache`/`EmbeddingStore` patterns).
- **Reuse SigLIP 2 beyond search**: zero-shot shot classification by embedding frames against text anchors ("a person talking to a camera", "a screen recording of a code editor", "gameplay footage"). The encoders are already on disk and ANE-resident.
- **`Generation/ModelCatalog` gains a `local` provider tier** (optional, Phase 4): route `generate_image` to a local diffusion backend (Core ML Stable Diffusion or an MLX sidecar), `generate_audio`/TTS to a local model. Cloud remains default where local can't compete (video gen).
- **Ollama VLM lane** (optional refinement): for screen recordings where heuristics are ambiguous, a local VLM (Qwen 2.5-VL et al. via Ollama) can be asked "which region of this screenshot is the user working in?" — used to *bias* the deterministic ROI, never as the only signal.

## 4. Extending the MCP server

The transport layer (streamable HTTP, per-session `Server` instances, mcpb for Claude Desktop) is solid — extend the *tool surface*, not the plumbing:

**New tools** (all in `ToolExecutor+*.swift` style, auto-exposed to MCP + in-app agent):

| Tool | Purpose |
|---|---|
| `analyze_clip` | Run the perception pipeline on a clip/asset; returns shot class, face boxes over time, saliency/ROI summary, OCR text regions, motion hotspots. **This gives Claude structured "eyes" on footage** — today it can only screenshot the canvas via `inspect_timeline`. |
| `convert_format` | The headline feature: one call converts the project (or a time range) between aspect ratios with intelligent reframing (§6). Params: target aspect, layout strategy (auto / named template), per-source overrides. Returns a summary of what it did so the agent can iterate. |
| `suggest_layouts` | Dry-run of the planner: returns ranked layout candidates with rationale, letting the agent (or user) pick before applying. |
| `set_reframe_keyframes` | Lower-level escape hatch: write a smoothed crop/position keyframe track for one clip from a supplied or computed ROI path (extends what `set_keyframes` can do with analysis-driven data). |
| `get_render_frame` | Return a rendered frame at time T as an image (higher-fidelity than the current overview screenshot) so agents can verify results visually. |

**Protocol-level improvements:**
- **Progress notifications** for long operations (analysis, conversion, export) via MCP progress — today long tools risk client timeouts; the Generation module's job/poll pattern can back this.
- **MCP resources** for project state (timeline JSON, transcript, analysis results) so agents can read without burning tool calls; `registerResources` already exists as a stub-level surface to build on.
- **Pagination/altitude** on `get_timeline` for big projects (keep responses small for local models with modest context windows).
- Trimmed **tool profile for local agent mode** — 47 verbose tool schemas overwhelm small local models; define a curated subset + terser descriptions when the active client is Ollama.

## 5. Integrating local models without breaking the MCP/agent workflow

- **Tools are the contract.** Local AI lives in services (`Analysis/`, `LocalAI/`) called *by* `ToolExecutor` — MCP clients never know or care whether Vision, SigLIP, Ollama, or the cloud did the work. No schema changes to existing tools; only additions.
- **Deterministic core, LLM-optional refinement.** `convert_format` must work with no LLM at all (Vision + saliency + heuristics). VLM/LLM input is a bias signal layered on top. This means the feature is fast, offline, and testable — and Claude-over-MCP can still drive it and iterate on the result.
- **Async job pattern for long work.** Long analysis returns quickly with cached/partial results or a job id + progress notifications, mirroring the existing generation-job design, so neither the in-app agent loop nor MCP clients stall.
- **Feature flags + graceful fallback.** Provider selection in Settings; if Ollama isn't running, agent falls back to configured cloud client with a clear status line; if a Core ML model isn't downloaded yet, tools report a actionable "downloading model (x%)" error.
- **Undo-safe, editable output.** Everything the AI does lands as ordinary timeline state (transforms, crops, keyframes, project settings) in one undo group — a user can hit ⌘Z or hand-tweak any keyframe afterward. No opaque "AI layer."

## 6. Smart horizontal ↔ vertical conversion — design

This is the centerpiece, and the codebase is unusually well-prepared: clips already carry `transform` + `crop` with **keyframe tracks** (`positionTrack`, `scaleTrack`, `cropTrack`), and `apply_layout` already computes cover-crops into normalized layout slots with continuous `anchorX`/`anchorY` framing bias. **Smart reframing = an analysis pass that generates anchors and keyframes for existing machinery.**

### Pipeline (new `Reframe/` module orchestrating `Analysis/`)

**Stage A — Shot classification** (per clip, cached per asset):
- Sample frames at ~2 fps, downscaled.
- Signals: face presence/size/persistence (Vision `VNDetectFaceRectanglesRequest`), OCR text density (`VNRecognizeTextRequest` — screen recordings are text-dense), SigLIP 2 similarity to text anchors ("person talking to camera" / "computer screen recording" / "b-roll").
- Output: `talkingHead | screenRecording | broll | unknown` with confidence. Existing PiP layouts give a strong prior: the small inset clip is almost certainly the talking head.

**Stage B — Region-of-interest analysis** (per clip, time-varying):
- *Talking head*: face landmarks → stable face box; temporal smoothing (one-euro filter); framing rules (eyes at upper third, headroom %). Output: a near-static or slowly-drifting ROI.
- *Screen recording*: importance map per sampled frame =
  - attention + objectness saliency (`VNGenerateAttentionBasedSaliencyImageRequest`),
  - OCR text-block clusters (where content is),
  - **motion energy** via frame differencing (where things are *changing* — typing, scrolling, cursor activity; cheap with vImage/Core Image),
  - optional local-VLM bias ("which app window is being used?").
  - Fuse into a scored grid → pick the ROI rect that covers the top-scoring region at the slot's aspect.
- *Temporal policy* (what separates good from seasick): hysteresis (don't move for small score changes), minimum dwell time, and **cut-don't-pan** — when the ROI jumps far, insert a keyframe cut rather than a slow drift; only ease for small corrections.
- Output: `ROITrack` — a sparse, smoothed sequence of normalized rects.

**Stage C — Layout synthesis** (`SmartLayoutPlanner`):
- Input: target aspect (9:16), classified clips grouped by simultaneity (what's on screen together).
- Mapping rules, e.g. for your exact workflow: `{main: screenRecording, inset: talkingHead}` in 16:9 PiP → **vertical stack**: screen recording in a ~1:1 top slot (ROI-zoomed), talking head in the bottom slot at ~40–50% height (face-framed, much more prominent). Captions/text repositioned to the safe band.
- Extend `VideoLayout` with **vertical-native templates**: `vertical_split` (top/bottom with configurable ratio), `vertical_face_top`, `vertical_full_face_pip` — or better, make slot geometry **parametric over canvas aspect** so each template knows its 16:9 and 9:16 forms (this also gives you the reverse 9:16 → 16:9 direction for free).
- Emits a `ReframePlan` (pure value type — unit-testable without rendering).

**Stage D — Application** (`ReframeApplier`):
- One undoable transaction: `setProjectSettings(aspectRatio:)` → per-clip slot transforms via the `apply_layout` code path → ROI tracks written as `cropTrack`/`positionTrack`/`scaleTrack` keyframes → text/caption layout adjustments.
- Non-destructive: source clips untrimmed, everything is transform/crop state. Optionally apply to a **duplicated project** ("Create 9:16 version") so the horizontal master stays pristine — recommended default for the repurposing workflow.

**Surfaces:** toolbar button ("Repurpose → 9:16"), `convert_format` MCP tool, and an agent **Skill** (the `Skills/` catalog exists) documenting the workflow so Claude drives it well.

## 7. Phased approach

**Phase 0 — Fork hygiene (days):** build & test the fork (`swift build`, `swift test`); keep `upstream` remote and put all work in new modules/files to stay rebase-able; decide Sentry/telemetry policy for your build; read `ToolExecutor+Layout.swift` and `CustomVideoCompositor` closely.

**Phase 1 — MVP: static smart vertical conversion (biggest impact, ~2–3 weeks):**
- `Analysis/`: face detection + saliency + OCR density on sampled frames; shot classification; **single static ROI per clip** (no keyframes yet).
- `Reframe/`: `SmartLayoutPlanner` + `ReframeApplier`; 2–3 vertical templates; project-duplication flow.
- `convert_format` tool + toolbar button.
- This alone fully delivers your example workflow (PiP screencast → vertical top/bottom with big talking head and sensibly-cropped screen), because the talking head barely moves and a well-chosen static crop of a screen recording is 80% of the value.

**Phase 2 — Dynamic reframing (~2–3 weeks):** time-varying ROI tracks with smoothing/hysteresis/cut-don't-pan; motion-energy analysis for screen recordings; keyframe emission; `analyze_clip` + `suggest_layouts` tools; analysis cache.

**Phase 3 — Local agent (~1–2 weeks):** `OllamaClient` + `LocalAgentClient`, provider picker in Settings, trimmed tool profile for small models, health checks/fallbacks.

**Phase 4 — Polish & optional generative:** MCP progress notifications + resources; VLM-assisted ROI refinement; local image-gen/TTS providers in `ModelCatalog`; parametric layouts for arbitrary aspect pairs; FCPXML export fidelity for reframed projects.

## 8. Challenges & mitigations

| Challenge | Mitigation |
|---|---|
| **Swift 6 strict concurrency** with Core ML/Vision (`MLModel`, `VNRequest` aren't Sendable) | Follow the in-repo precedent: `VisualEmbedder` is `@unchecked Sendable` behind a controlled interface; put analysis in a dedicated actor; never touch the compositor's render path from analysis code. |
| **Analysis cost** (decoding video twice) | Sample at 1–4 fps, downscale to ≤512px, `AVAssetImageGenerator`/`AVAssetReader` with reduced size; ANE via `MLComputeUnits.all`; cache per asset keyed by content hash (existing `EmbeddingStore` pattern). A 10-min screencast should analyze in well under a minute. |
| **Temporal instability** (jittery/seasick crops) | One-euro filtering, hysteresis, min-dwell, cut-don't-pan policy; clamp zoom levels; golden tests on ROI tracks (the repo already has this test culture — `SegmentTrimInvariantTests`, kernel golden tests). |
| **Coordinate-system soup** (Vision's bottom-left normalized coords vs. the timeline's top-left normalized canvas coords vs. source pixels, plus crop-then-transform ordering) | One conversion utility with exhaustive unit tests, modeled on the existing `TransformCropTests`. Get this right before anything else — every bug will look like "AI picked a bad crop" when it's a flipped Y axis. |
| **Aspect-change semantics** — what happens to existing clip transforms when the canvas flips 16:9 → 9:16 | Study `setProjectSettings`/`AspectPreset` resize behavior first; prefer the duplicate-project flow so conversion always *recomputes* layout rather than inheriting rescaled transforms; text/captions need their own vertical-safe-area rules. |
| **Small local models vs. 47 verbose tools** | Curated tool subset + short descriptions in local-agent mode; keep `convert_format` coarse-grained so one call does the whole job (less multi-step tool orchestration for weak models). |
| **Ollama not running / model not pulled** | Health check on launch + clear status in Settings; automatic fallback to the configured cloud client; never block editor startup on AI availability. |
| **Fork drift vs. active upstream** | New code in new modules; additions (not edits) to `ToolDefinitions`; periodic rebases; upstream may welcome PRs for the layout/analysis groundwork — less to carry. |
| **macOS 26-only APIs** | Non-issue: upstream already requires Tahoe/arm64 (SpeechAnalyzer is already used). |

## 9. New files / modules

```
Sources/PalmierPro/
├── LocalAI/
│   ├── ModelRegistry.swift            # generalized from Search/Models/ModelDownloader
│   ├── OllamaClient.swift             # localhost:11434 REST + streaming + discovery
│   ├── LocalAgentClient.swift         # third Agent/Clients implementation
│   └── LocalAIStatus.swift            # availability, health, settings state
├── Analysis/
│   ├── FrameSampler.swift             # low-fps downscaled frame extraction (reuse Search's)
│   ├── ShotClassifier.swift           # face/OCR/SigLIP-anchor fusion → shot class
│   ├── FaceTracker.swift              # Vision faces + landmarks + temporal smoothing
│   ├── SaliencyAnalyzer.swift         # attention/objectness saliency maps
│   ├── ScreenContentAnalyzer.swift    # OCR blocks + motion energy → importance grid
│   ├── ROITrack.swift                 # time-varying ROI value type
│   ├── ROISmoother.swift              # one-euro / hysteresis / cut-don't-pan policy
│   └── AnalysisCache.swift            # per-asset persisted results
├── Reframe/
│   ├── ReframePlan.swift              # pure value type: the planned conversion
│   ├── SmartLayoutPlanner.swift       # classification + ROI → plan
│   ├── ReframeApplier.swift           # plan → undoable timeline mutations
│   └── VerticalTemplates.swift        # aspect-parametric extensions to VideoLayout
├── Agent/Tools/
│   ├── ToolExecutor+Analyze.swift     # analyze_clip, suggest_layouts
│   └── ToolExecutor+Reframe.swift     # convert_format, set_reframe_keyframes
│   └── (ToolDefinitions.swift: additive entries only)
└── Settings/  (extend)                # AI-provider picker, local model management UI

Tests/PalmierProTests/
├── Analysis/   # coordinate conversion, classifier fixtures, ROI smoothing goldens
└── Reframe/    # planner unit tests, applier undo tests, aspect round-trip tests

Agent/Skills/   # new skill: "Repurpose horizontal → vertical" workflow doc for agents
```

---

### TL;DR decision summary

1. **Perception = Apple Vision + existing SigLIP 2 Core ML** (native, ANE-fast, deterministic) — not a VLM.
2. **LLM = pluggable third agent client (Ollama)** next to the existing Anthropic/Palmier clients.
3. **Reframing = analysis that writes anchors + keyframes into the existing `apply_layout`/`cropTrack` machinery**, applied as one undoable transaction on a duplicated project.
4. **MCP grows by addition only** (`convert_format`, `analyze_clip`, progress, resources) so Claude/Codex/Cursor workflows never break.
5. **Phase 1 MVP = static smart crop + vertical templates + one tool + one button** — it fully covers the screencast-PiP → vertical-short workflow.
