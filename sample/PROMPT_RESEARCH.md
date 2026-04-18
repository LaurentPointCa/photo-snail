# VLM Prompt Engineering — Research & Results

Standalone reference for the PhotoSnail Qwen3-VL prompt work. Captures the web research findings, the tactics we tested empirically, and what won.

**Companion doc**: [`MODEL_COMPARISON.md`](MODEL_COMPARISON.md) holds the full per-iteration outputs for 12 reference photos across 20 prompt versions.

**Setup under test**:
- Model: `mlx-community/Qwen3.6-35B-A3B-4bit` via `mlx-vlm` (OpenAI-compatible endpoint).
- Image pipeline: 1024 px long edge, JPEG q=0.8 (matches production PhotoSnail pipeline).
- Sampling used for all iterations: `temperature=0.3, max_tokens=1024` (Qwen's own VL-task recommendation is different — see "Open experiments").
- Target: description + search-ready tags for Apple Photos.app, which tokenizes on whitespace.

---

## 1. Research sources

Two web-research streams, both run 2026-04-18. Full citations at the end of each finding.

### General VLM prompt engineering
1. **NVIDIA VLM Prompt Engineering Guide** — role prompting, anomaly-focus, structured (JSON) output, comparative-context injection, directional reasoning. [developer.nvidia.com](https://developer.nvidia.com/blog/vision-language-model-prompt-engineering-guide-for-image-and-video-understanding/)
2. **JoyCaption Straightforward prompt** (fpgaminer) — "confident, definite language", "omit mood", "never mention what's absent", "quote text exactly". Shipped as a working production prompt. [github.com/fpgaminer/joycaption](https://github.com/fpgaminer/joycaption)
3. **Chain-of-Verification (CoVe)** — draft → generate verification questions per claim → answer → rewrite. Reduces object/activity hallucination. [learnprompting.org](https://learnprompting.org/docs/advanced/self_criticism/chain_of_verification)
4. **TriPhase Prompting (TPP)** — MDPI 2025. Scene → objects → attributes phased analysis; claims hallucination reduction. [mdpi.com/2076-3417/15/7/3992](https://www.mdpi.com/2076-3417/15/7/3992)
5. **KeyLLM pattern** (Grootendorst) — few-shot exemplars with explicit GOOD/BAD tags, fixed output shape. [maartengrootendorst.com/blog/keyllm](https://www.maartengrootendorst.com/blog/keyllm/)
6. **Controlled vocabulary for photo tagging** — organizepictures.com, photography.tutsplus.com. Pre-defined taxonomy (people/places/objects/events/text/activities) with "prefer X over Y" pairs.
7. **EMNLP 2024 — Does Object Grounding Really Reduce Hallucination?** — confidence-gated proper-noun naming ("Name a brand ONLY if logo visible"). [aclanthology.org/2024.emnlp-main.159.pdf](https://aclanthology.org/2024.emnlp-main.159.pdf)
8. **MachineLearningMastery — 7 prompt tricks to mitigate hallucinations** — contrastive GOOD/BAD exemplars as the strongest single lever for over-inference. [machinelearningmastery.com](https://machinelearningmastery.com/7-prompt-engineering-tricks-to-mitigate-hallucinations-in-llms/)
9. **NVIDIA NIM — Structured Generation for VLMs** — JSON schemas are more reliable than colon-headers; pair with "first character must be `{`" to kill preamble drift. [docs.nvidia.com/nim/vision-language-models](https://docs.nvidia.com/nim/vision-language-models/latest/structured-generation.html)

### Qwen3-VL specifics
1. **Qwen3-VL-8B-Instruct model card** — official VL-task sampling: `temperature=0.7, top_p=0.8, top_k=20, repetition_penalty=1.0, presence_penalty=1.5`. Different from text tasks (`top_p=1.0, top_k=40, temperature=1.0`). [huggingface.co/Qwen/Qwen3-VL-8B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct)
2. **Qwen3-VL Technical Report (arXiv 2511.21631)** — DeepStack architecture (vision features injected at multiple LLM layers); improved spatial grounding vs Qwen2.5-VL. [arxiv.org/abs/2511.21631](https://arxiv.org/abs/2511.21631)
3. **Qwen Look Again (arXiv 2505.23558)** — "long reasoning dilutes visual tokens, causing visual information to receive less attention and may trigger hallucinations." Text-only reflection (chain-of-thought) *hurts* VLMs unless visual context is re-injected. [arxiv.org/html/2505.23558v2](https://arxiv.org/html/2505.23558v2)
4. **Qwen structured output docs** (Alibaba Cloud) — recommends `outlines` library with Pydantic schemas for local Qwen structured output. Warning: "do not set `max_tokens` with structured output — truncates JSON." [alibabacloud.com/help/en/model-studio/qwen-structured-output](https://www.alibabacloud.com/help/en/model-studio/qwen-structured-output)
5. **Qwen VL uses ChatML** — respects system vs. user role messages; image-first in user turn is the conventional ordering.

### Key framing from the research

- **Chain-of-thought works for text LLMs but HURTS VLMs.** The "long reasoning dilutes visual tokens" finding from Qwen Look Again was the single most counterintuitive research result — and it was confirmed empirically (v18 TriPhase regressed).
- **JSON beats colon-headers for local model format compliance**. Multiple independent sources agreed (NVIDIA, Qwen docs, Medium practitioners). "First character must be `{`" is the recommended preamble-killer.
- **4-bit MoE quantization degrades color/small-text more than dense 4-bit**. The 35B-A3B architecture has only ~3B active params per token; quant noise on the active experts hits fine perception hard. Our photo 3 red-vs-orange failures likely trace back here.

---

## 2. Tactics tested → iteration results

Each research tactic was tested in a separate iteration (v11–v20). Results are empirical, on 12 reference photos, same image pipeline and sampling for all.

| v | Tactic | Source | Key finding |
|---|---|---|---|
| v11 | Confident, definite language — "no 'appears to be'"; never mention absent | JoyCaption | **Unlocked photo 3 red sweatshirt color** for the first time across 11 iterations. Confidence language appears to free the model from hedging — counterintuitively, it may help perception as well as phrasing. |
| v12 | Quote text exactly (brands, signs, labels) | JoyCaption | First `travel` tag on photos 11/12. First graffiti text (`bonar`) quoted. Bucharest correctly spelled. |
| v13 | Six-category taxonomy (people/objects/places/events/text/colors) | Controlled vocabulary literature | **Regression.** Heavy scaffolding pulled the model toward category-fitting rather than observation; swapped `birthday` → `meal` on photo 1. Worst iteration of the batch. |
| v14 | Few-shot exemplars (3 inline GOOD-shape examples) | KeyLLM | **First `bmw m` identification ever** across any iteration. Few-shot brand naming is the cheapest way to teach brand recognition. |
| v15 | Contrastive negative exemplars ("GOOD: … BAD: christmas (green+red is just clothing) Reason: …") | NVIDIA + hallucination literature | **Zero false positives on photo 10** (no christmas, no holiday, no mannequin — all three earlier iterations' FPs killed). Strongest false-positive-suppression pattern tested. |
| v16 | Proper-noun confidence gating ("name a brand ONLY if logo visible") | EMNLP 2024 grounding | Photo 11 `boots` storefront identified. Photo 12 `Arcul de Triumf` Romanian name correct. |
| v17 | Chain-of-Verification two-pass self-audit | Learn Prompting CoVe | **Photo 7 `repotting` recovered** (lost since v7). Photo 11 `Regent Street` + `Burberry` storefront. Works — but gains were modest. |
| v18 | TriPhase hierarchical (objects → scene → output) | MDPI 2025 | **Regression.** Model emitted all three phases verbatim, doubling output length; photo 11 tag format broke (no commas). **Empirically confirms the Qwen Look Again finding**: long reasoning dilutes visual attention. |
| v19 | JSON structured output + "first char must be `{`" | NVIDIA + Qwen docs | **All 12 photos parsed as valid JSON, zero preamble drift.** Clean `birthday`/`repotting`/`renovation`/`travel` tags. Format compliance unlocked reliable downstream parsing. |
| v20 | Consolidation of v11/v12/v14/v15/v17/v19 winners | — | **Best overall scorecard of all 14 iterations tested.** See next section. |

### Prompting tactics confirmed as winning

1. **Confident, definite language** (v11). "No 'appears to be'" also freed perception, not just phrasing.
2. **Quote text exactly** (v12). Single sentence; unlocks brand/landmark/sign identification.
3. **Few-shot brand exemplars** (v14). 2–3 inline shape-examples pull out brand names principle-based rules alone can't.
4. **Contrastive GOOD/BAD + reason** (v15). Strictly better than abstract "don't speculate" rules for false-positive suppression.
5. **JSON output + "first char must be `{`"** (v19). Cleanest format compliance we measured.
6. **Self-audit gate tying tags to prose** (v17, v9). "Tag category X only if you described its marker in the prose" — prevents free-floating categorization.

### Prompting tactics confirmed as failing (for this model+task)

1. **Long category vocabulary lists in prompt body** (v4, v5, v6). Tempts force-matching; the model picks *something* from the list even when evidence is thin.
2. **Heavy per-category taxonomy scaffolding** (v13). Over-constrains; swaps natural inference for category-fitting.
3. **Multi-phase / CoT / TriPhase** (v18). Dilutes visual token attention in VLMs — the research warned about this and our empirical result matched. **Don't use CoT with Qwen3-VL for perception-critical tasks.**
4. **"Prefer omission" without scope** (v5). Bleeds into content description; killed photo 1 cake mention.

---

## 3. Cross-iteration scorecard

14 criteria across the 12 reference photos. `✅` = pass, `❌` = fail.

| Criterion | v4 | v9 | v10 | v11 | v12 | v14 | v15 | v17 | v19 | **v20** |
|---|---|---|---|---|---|---|---|---|---|---|
| P1 describes cake | ✅ | ❌ | ✅ | ❌ (donuts) | ❌ (bagels) | ❌ (bread) | ✅ | ❌ | ✅ | ✅ |
| P1 `birthday` tag | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | **✅** |
| P3 red sweatshirt color | ❌ | ❌ | ❌ | **✅** | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ |
| P3 no `hiking`/`camping` FP | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P4 `birthday` tag | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ |
| P5 `bmw m` tag | ❌ | ❌ | ❌ | ❌ | ❌ | **✅** | ❌ | ❌ | ❌ | **✅** |
| P6 `renovation` tag | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| P7 `repotting` tag | ✅ | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ |
| P10 no `mannequin`/`christmas` FP | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P11 `london` tag | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P11 `travel` tag | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| P12 Bucharest/Romania | ❌ | ⚠️ | ⚠️ | ⚠️ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| P12 `travel` tag | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Format compliance | OK | OK | OK | OK | OK | OK | OK | OK | **JSON** | **JSON** |

**Totals** (count of `✅`, excluding "Format" row): v4=6, v9=8, v10=7, v11=8, v12=10, v14=8, v15=9, v17=9, v19=11, **v20=12**.

---

## 4. Winning prompt (v20)

Full text lives in `MODEL_COMPARISON.md` under "Revised Qwen prompt — v20". Summary of what's in it:

1. **JSON schema with explicit "first character must be `{`"** — kills preamble drift.
2. **Confident-language block** (no "appears to be", no mood, no speculation, no meta-commentary, never mention absent).
3. **Object-type naming rule** ("vacuum" not "black-handled tool").
4. **Quote-text-exactly clause** with brand examples.
5. **Location/landmark identification** with multi-cue requirement ("red double-decker bus + British signage = London").
6. **Four-line inline few-shot** for BMW M, Dyson, London, Bucharest.
7. **Negative-exemplar "do NOT tag" list** (hike without gear, christmas from color coincidence, meal without eating, mannequin for statues).
8. **Positive-exemplar "DO tag when marker present" list** (cake+candles → birthday, exposed roots+soil → repotting, etc.).
9. **Filler skip-list** (wall/floor/ceiling/sky/ground/background/surface/object/scene).

v20 wins 12/14 criteria. The two it doesn't:
- **Photo 3 sweatshirt color** — Qwen3.6-35B-A3B-4bit perceives the sweatshirt as orange in ~70% of runs; only v11/v12/v15 got red right, and they lost other criteria to do it. Not prompt-fixable.
- **Photo 11 London sub-specificity** — v15/v16/v17 got `Piccadilly Circus`/`Regent Street`/`Burberry` storefronts but only by emphasizing proper-noun confidence at the expense of other tags. v20 takes `london` + `travel` as the safer baseline.

---

## 5. Model-level failures (NOT prompt-fixable)

These reproduced across every prompt we tested. Treat as baseline model characteristics of Qwen3.6-35B-A3B-4bit at 1024 px:

| Issue | Photo | Best prompt got it right |
|---|---|---|
| Red vs orange sweatshirt | 3 | ~30% of iterations |
| Pajama color ("red sleeves" vs actual gingham) | 2 | 0% of iterations |
| Cake vs pizza/donuts/bagels (food identification variance) | 1 | ~50% of iterations |
| BMW M badge vs generic "M logo" | 5 | Only v14 + v20 (few-shot) |

**Likely root cause**: 4-bit quantization on a MoE (only ~3B active params per token) amplifies color/fine-detail noise on active experts. Per the Qwen3-VL research, the dense 4-bit quants hold captioning quality better than the MoE equivalents.

**Mitigations worth testing** (in §6 below): higher resolution, full precision, Qwen-official VL sampling params.

---

## 6. Open experiments — not yet run

Documented here so future sessions can pick them up.

### High priority
- **A/B: current sampling (`temp=0.3`) vs. Qwen-official VL sampling (`temp=0.7, top_p=0.8, top_k=20, presence_penalty=1.5`)**. Official params may improve perception on our stubborn failures (photo 3 color, photo 1 cake). Trade-off: lower reproducibility. Run v20 with both sampling configs on all 12 photos.
- **A/B: 1024 px vs 1280 px long edge**. Qwen3-VL's DeepStack dynamic-resolution benefits from more pixels. Costs ~50% more tokens per image but may fix color/brand perception.
- **Outlines / constrained decoding for JSON**. `mlx-vlm` supports Pydantic-schema-constrained decoding. Eliminates the remaining risk of JSON drift in production batches. Alibaba's official recommendation.

### Medium priority
- **System message vs user message for format rules**. Qwen's ChatML template respects system messages well. Moving the rules into system + keeping user turn image-first may reduce visual-token interference.
- **Higher-precision model** (Qwen3.6-35B-A3B FP16 or 8-bit). Direct test of the "4-bit MoE hurts perception" hypothesis. Costs ~2–4× memory and latency.
- **Test on photos outside the tuning set**. All 12 reference photos have been seen by every prompt iteration. A clean validation set of new photos is needed to confirm v20 isn't overfit.

### Low priority / exploratory
- **Qwen3-VL-Thinking variant** for perception-critical photos (if the research's "re-attention visual information" improvements land the cake/color failures).
- **Multimodal retrieval augmentation** — pre-index a small set of "reference looks" (what a birthday cake looks like, what an exposed plant root looks like) and include the closest match as a reference image in the prompt. NVIDIA VLM guide's "comparative context injection" tactic.

---

## 7. Practical notes

### The MODEL_COMPARISON.md doc

Every iteration's output is pasted verbatim under each photo. Cross-iteration regressions can be audited directly — no need to re-run. When adding a new prompt, follow the existing sectioning (add the prompt to "Prompts under test" at the top, then a subsection per photo with the raw output).

### The test harness

Lives in `/tmp/prompt-iterate/`. Python script (`run_iter.py`) that downsizes with Pillow, base64-encodes, POSTs to the OpenAI-compatible endpoint, saves results to JSON. `inject_iter.py` merges JSON results into MODEL_COMPARISON.md. Not committed to the repo — it's a one-off tool. Backup copies of all v11–v20 results JSON are in `/tmp/v{11..20}_results.json`.

### Tag format policy (Photos.app search)

Photos.app tokenizes the description field on whitespace. Tags stored as `party hat` (with space) match both "party" and "hat" searches; `partyhat` matches neither. All prompts v3 onwards enforce this. See the memory entry `feedback_tag_format.md`.

### Prompt iteration principle (user's directive)

Don't add per-case exemplar patches — teach principles. See `feedback_prompt_iteration_principles.md`. The v11–v20 batch honored this: no exemplar is specific to the 12 sample photos; the BMW M example in v14 is illustrative of the shape, and the negative exemplars in v15 are illustrative of the failure modes, not patches for specific sample images.
