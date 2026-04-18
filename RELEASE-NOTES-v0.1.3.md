# PhotoSnail v0.1.3

Adds an OpenAI-compatible provider path for **locally-hosted** servers (mlx-vlm, LM Studio, vLLM), per-model-family configuration, and a Qwen-tuned v20 default prompt that hits 12 of 14 criteria on our 12-photo benchmark vs. gemma4's 6. End-to-end this is ~**6× faster** than the Ollama + gemma4:31b path on Apple Silicon.

## Headline: two provider paths, interchangeable

PhotoSnail now supports two LLM provider paths, switchable at runtime from Settings or via `--provider` on the CLI:

| Provider | Model | Per photo | 10,000 photos | Benchmark hit rate |
|---|---|---|---|---|
| Ollama | `gemma4:31b` (dense) | ~65 s | ~7.5 days | 6 / 14 |
| OpenAI-compatible | `Qwen3.6-35B-A3B-4bit` via mlx-vlm (MoE) | **~10 s** | **~28 hours** | **12 / 14** |

The gap in speed comes from the MoE architecture (~3B active params per token) plus mlx-vlm's Apple Silicon optimization. The gap in criteria hit rate comes from a 20-iteration prompt-engineering batch with web-research-backed tactics — see `sample/PROMPT_RESEARCH.md` for the methodology and `sample/MODEL_COMPARISON.md` for the verbatim per-iteration outputs across all 20 prompts × 12 reference photos.

The Ollama path remains the privacy-first default. The OpenAI-compatible path is explicitly scoped to **locally-hosted** servers; a persistent banner in Settings reminds you that PhotoSnail is not intended to point at `api.openai.com`.

## What's new

### OpenAI-compatible provider path

- **New `LLMClient` protocol** in `PhotoSnailCore` with `listModels()`, `preflight(model:)`, `generateCaption(...)`, `generateText(...)`. Implementations: `OllamaClient` (existing, refactored to conform) and `OpenAIClient` (new).
- **OpenAI mapping**: `GET /models` → `LLMModel` entries, `POST /chat/completions` with multimodal `image_url` data-URL messages for captions, plain text messages for translation.
- **Settings schema v2**: adds `apiProvider` (`ollama` | `openai-compatible`) and an `openai` connection block (`baseURL`, `apiKey`, `headers`). Old v1 files decode cleanly with `.ollama` and defaults — no manual migration needed.
- **CLI flags**: `--provider ollama|openai`, `--openai-url`, `--openai-key`, `--openai-header K=V`. `--api-test` is the new provider-agnostic probe (`--ollama-test` kept as an alias).
- **Env-var override**: `PHOTO_SNAIL_OPENAI_API_KEY` mirrors the Ollama one — applied at runtime, never persisted.
- **GUI**: provider segmented picker in Settings. Connection fields moved up next to the provider selector so switching providers doesn't require scrolling. Test Connection button uses a 15 s timeout for the test path (vs. 1800 s for production captioning) so a misconfigured URL fails fast.
- **ATS**: both `Info.plist` files now set `NSAllowsArbitraryLoads = true`. Required because `NSAllowsLocalNetworking` only covers `.local` + unqualified hostnames, not Bonjour variants like `*.localdomain` or raw LAN IPs. The app's only network traffic is user-configured LLM endpoints, so this isn't a meaningful expansion of attack surface.

### Qwen3.6 + v20 default prompt

- **New Qwen-tuned default prompt** (`PromptBuilder.qwenDefaultPrompt`, aka v20) automatically selected for model families `qwen3-6`, `qwen3-vl`, `qwen2-vl`. Emits JSON (`{"description": "...", "tags": [...]}`) — cleaner format compliance than colon-headers, zero preamble drift measured across 12 photos.
- **Winning tactics from the v11–v20 research batch** (documented at `sample/PROMPT_RESEARCH.md`):
  - JSON output with explicit "first character must be `{`" → format compliance.
  - Confident, definite language ("no 'appears to be'") → freed perception on some photos.
  - "Quote text exactly" → brand names (BMW M, Dyson) and storefront OCR (Boots, Burberry, Regent Street).
  - Few-shot brand exemplars → BMW M identification (nothing else worked).
  - Contrastive negative exemplars ("BAD: christmas (no christmas tree, green+red is just clothing)") → killed photo-10-style false positives cleanly.
  - Tag self-audit gate ("category tag allowed only if the marker appears in your prose").
- **Gemma4 keeps its existing default prompt.** Switching between families via the GUI or CLI swaps the prompt default without losing your custom overrides for either family.
- **CaptionParser now handles JSON and DESCRIPTION:/TAGS: formats.** Detects `{`-prefixed output, brace-balanced extraction (tolerates markdown fences, preamble, escaped quotes, `{` inside strings). Falls back to the legacy colon-header parser when no valid JSON is present. 15 unit tests cover both paths.

### Per-model-family configuration

- **`Settings.modelConfigs`** (new v3 schema field): a dict keyed by `Sentinel.shortFamily(of:)` — each entry holds that family's `customPrompt`, `sentinelVersion`, `customSentinel`, and `promptLanguage`. Switching models swaps which entry is "active" without losing the others.
- **`Sentinel.shortFamily(of:)`**: new helper that strips org prefixes (`mlx-community/`), quantization suffixes (`-4bit`, `-q4_K_M`, `-gptq`, `-mlx`, `-bf16`, …), parameter-size suffixes (`-35b`, `-a3b`), and instruction-tuning suffixes (`-instruct`, `-chat`). Used only in the `propose(...)` path — existing persisted sentinels keep parsing unchanged.
- **Examples**:
  - `mlx-community/Qwen3.6-35B-A3B-4bit` → family `qwen3-6`
  - `TheBloke/Llama-3.2-7B-Instruct-GPTQ` → family `llama-3-2`
  - `gemma4:31b` → family `gemma4` (unchanged)
- **Migration**: v1/v2 files seed a single `modelConfigs` entry for the active family using the legacy top-level `customPrompt`/`sentinel`/`promptLanguage` fields. On save we still emit those top-level fields for forward-compat with older readers.

### Lock-watcher auto-resume fix (carried from 2026-04-18 hotfix)

Fixed a bug where the auto-start-when-locked toggle would drop into a paused state if the user briefly unlocked and re-locked mid-batch. The unlock-pause → re-lock path now correctly resumes the queue instead of leaving it stuck.

## Upgrading

Just install over the previous version. The queue DB migrates automatically. Settings migrate v1/v2 → v3 on first load with full backward compatibility.

If you want to try the Qwen path:

1. Install `mlx-vlm` (`pip install mlx-vlm`) or LM Studio or vLLM.
2. Start the server: `mlx_vlm.server --model mlx-community/Qwen3.6-35B-A3B-4bit --port 9090`.
3. In PhotoSnail Settings, switch provider to **OpenAI-compatible**, set base URL to `http://localhost:9090/v1`, pick the Qwen model.
4. The v20 prompt is applied automatically as the default for the `qwen3-6` family.
5. Accept the sentinel proposal (`ai:qwen3-6-v1` or a custom one — e.g. `ai:qwen36_4b-v20` if you want to pin it to the prompt iteration).

Your existing gemma4 sentinel is preserved in `modelConfigs["gemma4"]` — switching back to gemma4 restores its prompt, sentinel, and language.

## Internal

- New Swift files: `Sources/PhotoSnailCore/LLMClient.swift`, `Sources/PhotoSnailCore/OpenAIClient.swift`.
- New tests: `Tests/PhotoSnailCoreTests/CaptionParserTests.swift` (15 tests, both JSON and colon-header paths), `Tests/PhotoSnailCoreTests/SettingsMigrationTests.swift` (7 tests, v1/v2 → v3 migration).
- Existing test coverage extended: `Tests/PhotoSnailCoreTests/SentinelTests.swift` gains short-family tests.
- `bundle-gui.sh` adds `NSAllowsArbitraryLoads` to the GUI plist.
- Qwen3.6-35B-A3B-4bit via mlx-vlm validated end-to-end against the full pipeline (Vision side-channel + LLM caption + tag merge + Photos.app write-back + sentinel bootstrap).

## Known limitations

- **Photo 3 / photo 2 color perception on Qwen**: the 4-bit MoE quantization (~3B active params per token) occasionally mis-reads colors — red sweatshirt → "orange" in ~70% of runs, gingham → "red sleeves". Not prompt-fixable; a higher-precision quant or a dense model would address it. Gemma4 at full precision is better here.
- **Preflight is Ollama-hardcoded when provider is OpenAI-compatible** (carried forward from v0.1.2). The HTTP probe hits the right endpoint, but `PreflightSheet` copy still says "Start Ollama" / `brew install ollama` even when the provider is OpenAI-compatible. Tracked in `TODO.md` → "Potential future improvements".
- **Diagnostic flags (`--list-models`, `--api-test`) still return before the settings-save step**, so combining them with `--ollama-url` etc. doesn't persist the config. Re-run without the diagnostic flag.
