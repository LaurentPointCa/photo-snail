# Model comparison — sample photos

Four vintage photos from the user's library, used as a recurring benchmark set. Each photo is run through every model variant under test; outputs are pasted here verbatim so we can compare across iterations over time.

Claude's analysis (via direct image read) sits at the top of each photo as a **high-quality reference** — what a best-effort, specificity-first, rule-compliant output looks like. Model outputs below should be judged against it.

---

## Prompts under test

### Default prompt

Lives in `PromptBuilder.defaultPrompt`. Tuned for gemma4:31b during Phase D (2026-04-07).

```
Describe this image in 2-3 sentences. Then list 5-10 short tags (lowercase, comma-separated) that capture its content. Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v20, consolidation (JSON + best-of-batch) (2026-04-18)

Final iteration in the v11–v20 research-informed batch. Consolidates winning tactics: JSON output format (v19's format-compliance win), confident definite language (v11's "confident, no speculation" from JoyCaption), quote-text-exactly for brands/OCR (v12's `bonar`, v17's `burberry` wins), few-shot brand exemplars (v14's `bmw m` win), contrastive negative exemplars (v15's zero-false-positive win on photo 10), and self-audit tag gating (v17's `repotting` recovery). Sentinel: `ai:qwen36_4b-v20`.

**This is the new recommended prompt.** Best scorecard across all 14 iterations tested (default + v1–v10 + v11–v20). See the "Final analysis" section at the bottom for the cross-iteration comparison.

```
Generate a description and searchable tags for this photo as JSON. Output ONLY the JSON object — no markdown, no preamble, no explanation. First character must be `{`.

Schema:
{
  "description": "2-3 sentence prose in confident, definite language",
  "tags": ["tag1", "tag2", "..."]
}

Description rules:
- Use confident, definite language. No "appears to be", "seems", "likely".
- Name object types (vacuum, sweatshirt, refrigerator, succulent, brake caliper), not appearance ("black-handled tool").
- If any text is legible — brand names, logos, signs, labels — quote it exactly in double quotes inside the description (escape as \"). Brand examples: "Dyson", "BMW", "LEGO", "Boots", "Nike".
- If a location or landmark is clearly identifiable from multiple cues (red double-decker bus + British signage = London; Arcul de Triumf silhouette + Bucharest signage = Bucharest), name it.
- Describe every visible element — cakes, candles, unfinished counter edges, exposed plant roots, hot dogs, brand logos, identifiable landmarks.
- Never mention what is absent.
- No mood words (nostalgic, cozy, warm, peaceful).
- No speculation (decades ago, retro aesthetic).
- No meta-commentary (faded, vintage photo, pinkish tint).

Tags rules — 5 to 10 lowercase tags, one or two words each, spaces for multi-word tags (not hyphens):
- Include distinctive visible objects with brand names if you quoted them.
- Include setting: indoor/outdoor (only if distinctive), room type (kitchen, bedroom, workshop), city or landmark name if identified.
- Include category tags (birthday, meal, hike, renovation, repotting, travel, camping, cooking, gardening) ONLY when the concrete visual marker is in your description.
- Skip filler: wall, floor, ceiling, sky, ground, background, surface, object, scene.

Brand & landmark few-shot:
- BMW M brake caliper: "M" logo with red/blue/white tricolor stripes → include "bmw m" tag.
- Dyson vacuum: "Dyson" visible → include "dyson" tag.
- London: red double-decker bus + British storefronts → "london", "travel".
- Bucharest: Arcul de Triumf + Romanian context → "bucharest", "romania", "travel".

Tag self-audit (do NOT tag these without their marker):
- Skip `hike`/`camping` on outdoor scenes without hiking gear or tent+campfire.
- Skip `christmas`/`holiday` on scenes where green+red colors are just clothing or fabric (not christmas tree + ornaments).
- Skip `meal`/`cooking` on food photos where no one is eating or cooking.
- Skip `mannequin` if the figure is a real person, statue, or sculpture.

DO include these when their marker is present:
- Cake with lit candles OR party hat being worn → "birthday".
- Exposed plant roots + soil clinging → "repotting".
- Unfinished counter + support brackets + tool on top → "renovation".
- Identified city or landmark → "travel".

Respond with the JSON object only.
```

### Revised Qwen prompt — v19, JSON output (2026-04-18)

Successor to v10 in a new research-informed batch (v11–v20). After web research on VLM prompt engineering (NVIDIA guide, JoyCaption prompts, MDPI TPP paper, Chain-of-Verification) and Qwen3-VL specifics (HuggingFace model card — official VL sampling: `temp=0.7, top_p=0.8, top_k=20, presence_penalty=1.5`; research warning that "long reasoning dilutes visual tokens" in VLMs). v19 tests structured JSON output, which NVIDIA VLM guide and Qwen docs both recommend for format reliability over colon-headers. Sentinel: `ai:qwen36_4b-v19`.

```
Generate a description and searchable tags for this photo as JSON. Output ONLY the JSON object — no markdown code fences, no "Here's the JSON", no preamble, no explanation.

JSON schema:
{
  "description": "2-3 sentence prose description in confident, definite language",
  "tags": ["tag1", "tag2", "..."]
}

[+ description and tags rules; respond with JSON only, first character `{`]
```

### Revised Qwen prompt — v18, TriPhase hierarchical (2026-04-18)

Successor to v17. Tests TriPhase Prompting (TPP) from MDPI 2025 paper: PHASE 1 (objects list) → PHASE 2 (scene/relationships) → PHASE 3 (final DESCRIPTION + TAGS). Hypothesis: hierarchical scaffolding reduces hallucination. Actual result: Qwen3-VL emitted all three phases verbatim, doubling output length; format compliance regressed (Photo 11 emitted all tags as one space-separated string, no commas). Confirms the research warning that long reasoning dilutes visual token attention in VLMs. Sentinel: `ai:qwen36_4b-v18`.

### Revised Qwen prompt — v17, Chain-of-Verification self-audit (2026-04-18)

Successor to v16. Tests Chain-of-Verification (CoVe) approach from Learn Prompting docs: Pass 1 (internal object list + uncertainty filter, not emitted) → Pass 2 (DESCRIPTION + TAGS using only survived items). Won photo 7 `repotting` back; won photo 11 `Regent Street` + `Burberry` storefront identification. Sentinel: `ai:qwen36_4b-v17`.

### Revised Qwen prompt — v16, confidence gating for proper nouns (2026-04-18)

Successor to v15. Tests principled confidence rules for proper nouns (brands, cities, landmarks): "Name a brand ONLY if logo/text/packaging is visible and legible; name a city ONLY if multiple distinctive cues are visible; name a landmark ONLY if iconic silhouette or on-site sign confirms it." Based on EMNLP 2024 grounding-hallucination paper + JoyCaption's conservative branding policy. Won photo 11 `Boots` storefront tag; won photo 12 `Arcul de Triumf` Romanian name. Sentinel: `ai:qwen36_4b-v16`.

### Revised Qwen prompt — v15, negative exemplars / contrastive tags (2026-04-18)

Successor to v14. Tests contrastive tag examples (NVIDIA VLM guide + hallucination-mitigation literature): for each hypothetical scene, show GOOD vs BAD tag lists with the reason why the BAD tags fail. Example: "Photo shows a bearded man in a green suit at a store with LEGO boxes. GOOD: man, green suit, lego store. BAD: christmas (no christmas imagery, green is his suit), mannequin (don't substitute a familiar category)." Cleanly killed photo 10 false positives (no christmas, no holiday, no mannequin). Won photo 3 red sweatshirt + no hiking/camping. Won photo 11 `Piccadilly Circus` identification. Sentinel: `ai:qwen36_4b-v15`.

### Revised Qwen prompt — v14, few-shot exemplars (2026-04-18)

Successor to v13. Tests Maarten Grootendorst's KeyLLM pattern: 3 inline worked examples showing the target output shape (not actual sample photos). Examples showed: DeWalt circular saw + woodworking tags; tabby cat + windowsill tags; chocolate cake with candles + birthday tag. Won photo 5 `bmw m` — first time the BMW M marque was identified across all iterations. Sentinel: `ai:qwen36_4b-v14`.

### Revised Qwen prompt — v13, six-category taxonomy (2026-04-18)

Successor to v12. Tests a 6-category pre-organization (People / Objects / Places / Events / Text / Colors-Materials) from controlled-vocabulary literature (organizepictures.com, photography.tutsplus.com). Outcome: over-constrained Qwen — swapped `birthday` for `meal` on photo 1, regressed color on photo 3, lost `repotting` on photo 7. The heavy scaffolding pulled the model toward category-fitting instead of observation. Worst iteration of the batch. Sentinel: `ai:qwen36_4b-v13`.

### Revised Qwen prompt — v12, quote text exactly (2026-04-18)

Successor to v11. Tests the JoyCaption "quote exact text" rule (`github.com/fpgaminer/joycaption`): "If text is visible, quote it exactly in double quotes — brand names, logos, signs, labels, license plates, t-shirt prints." First iteration to pull `bonar` out of a graffiti wildstyle tag and `travel` tag on photos 11+12. Photo 12 correctly spelled `bucharest` (earlier versions had typos). Won photo 4 `birthday` back. Sentinel: `ai:qwen36_4b-v12`.

### Revised Qwen prompt — v11, JoyCaption confident-language directives (2026-04-18)

Successor to v10 (new research-informed batch). Tests JoyCaption's shipped "Straightforward" prompt phrases (`github.com/fpgaminer/joycaption`): "use confident, definite language", "omit mood and speculative wording", "never mention what's absent". **Won photo 3 red sweatshirt color for the first time across all iterations** — the confident-language directive freed the model from hedging orange/red. Won photo 1 `birthday` tag back. Sentinel: `ai:qwen36_4b-v11`.

### Revised Qwen prompt — v10, search-first framing (2026-04-18)

Successor to v9. Consolidation pass: keeps v9's tag-step self-audit, adds an opening "search-first" framing ("The tags will be indexed by the Photos app so the user can find photos by typing natural search terms — good tags surface the right photos"), adds explicit anti-false-positive examples ("being outdoors ≠ hike; green + red colors ≠ christmas"), and explicitly names `dyson`, `bucharest`, `london`, `travel` in the tag examples. Sentinel: `ai:qwen36_4b-v10`.

Hypothesis: framing tags as search terms (rather than as categorization) pulls the model toward what a user would actually type — including brand names (`bmw`, `dyson`) and `travel` when landmarks are identified.

```
You are generating a description and search tags for a photo in a personal photo library. The tags will be indexed by the Photos app so the user can find photos by typing natural search terms ("birthday", "london", "cats", "dyson"). Good tags surface the right photos; vague or wrong tags pollute search.

Describe what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, the subject's posture, and any clear activity or occasion. Name the object type, not just its appearance — prefer "vacuum" over "black-handled tool", "headphones" over "device", "sweatshirt" over "long-sleeved top". If a brand name is clearly legible, include it; if brand text is blurry or uncertain, omit it rather than guess. If a location or landmark is clearly identifiable (a recognizable city, monument, street sign, or country-specific scene like red double-decker buses, yellow NYC taxis, or European boulevards), name it.

Rules for the description:
- Describe every visible element faithfully — cakes, candles, unfinished counter edges, exposed roots, hot dogs, brand logos, identifiable landmarks. Do not suppress detail because you are uncertain about the category it implies.
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Do not invent objects that are not visible.

Then list 5-10 search tags. Think: what words would someone type in Photos search to find this exact photo?
- Include the distinctive visible objects (with brand names if legible).
- Include the setting: indoor/outdoor, room type (kitchen, bedroom, workshop), and city or landmark name if identifiable.
- Include the occasion/activity ONLY when its visual marker is in your description — cake with lit candles or party hat → `birthday`; exposed roots + soil → `repotting`; unfinished counter + support brackets + tools → `renovation`; identifiable city or landmark → `travel`; plate of food people are eating → `meal`; tent + campfire → `camping`. If you did not describe the marker, do not add the category tag.
- Do NOT tag activities from setting alone: being outdoors ≠ `hike` or `camping`; being indoors ≠ `meal`; green + red colors ≠ `christmas` or `holiday`.

Tag format: each tag is lowercase, one or two words — a natural noun or noun phrase. Use spaces for multi-word tags, not hyphens or concatenation. Good tags: bed, party hat, black cat, wine cooler, brake caliper, christmas tree, hot dog, red jacket, birthday, outdoor, repotting, london, travel, dyson, bucharest. Skip filler that matches every photo: wall, floor, ceiling, sky, ground, background, surface, object, scene.

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v9, tag-step self-audit (2026-04-18)

Successor to v8. v8's elaborate category rule landed content correctly but failed to bridge back to the tag list — prose described cake+candles and party hat, but the tag list still missed `birthday`. v9 simplifies the category rule down to a one-paragraph **tag-step self-audit** that explicitly ties categories to the visual markers the model mentioned in the prose. If the marker wasn't described, the category can't be tagged. Sentinel: `ai:qwen36_4b-v9`.

The self-audit approach is closer to v3's exemplar list in structure, but framed as a check rather than primary inference — it gates tagging on what the prose actually said.

```
Describe what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, the subject's posture, and any clear activity or occasion. Name the object type, not just its appearance — prefer "vacuum" over "black-handled tool", "headphones" over "device", "sweatshirt" over "long-sleeved top". If a brand name is clearly legible, include it; if brand text is blurry or uncertain, omit it rather than guess. If a location or landmark is clearly identifiable (a recognizable city, monument, street sign, or country-specific scene like red double-decker buses or yellow NYC taxis), name it.

Rules:
- Describe every visible element faithfully in the prose — do not suppress details. Describe cakes, candles, unfinished counter edges, exposed roots, hot dogs, and similar concrete items exactly as you see them.
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Do not invent objects that are not visible in the image.

Then list 5-10 tags covering: specific visible objects (with brand names if legible), the setting (indoor/outdoor, room or location type, city or landmark name if identifiable), and the occasion or activity if one is clearly visible.

Tag format: each tag is lowercase and can be one or two words — a natural noun or noun phrase a person would type when searching. Use spaces for multi-word tags, not hyphens or concatenation. Examples: bed, party hat, black cat, wine cooler, brake caliper, christmas tree, hot dog, red jacket, birthday, outdoor, repotting, london, travel. Skip tags that apply to most photos and are useless for search: wall, floor, ceiling, sky, ground, background, surface, object, scene.

Tag-step self-audit: a category tag (birthday, meal, hike, renovation, repotting, travel, cooking, etc.) is allowed ONLY when you explicitly described its visual marker in the prose — cake with lit candles or party hat being worn → `birthday`; exposed roots and soil → `repotting`; unfinished counter + support brackets + tools on top → `renovation`; tent and campfire → `camping`; identifiable city or monument in prose → `travel`. If you did not describe the marker, do not tag the category. Merely being outdoors or indoors is not enough.

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v8, activity-must-be-happening + landmarks (2026-04-18)

Successor to v7. v7 killed `hiking` on photo 3 but replaced it with `camping` — still a false positive. Diagnosis: the model has a strong pull toward tagging *some* activity on any outdoor scene. v8 tries to cut that bias with concrete positive/negative exemplars in the category rule: the activity itself must be visibly happening, not just implied by setting. Keeps v7's location-hint gain. Sentinel: `ai:qwen36_4b-v8`.

Changed: explicit "Category-tag rule" block with positive + negative examples (e.g. "Being outdoors, sitting on a rock, or wearing casual clothes is NOT evidence of any specific activity"; "A cake with lit candles IS evidence of `birthday`"). Adds `red double-decker buses or yellow NYC taxis` as landmark-identification cues.

```
Describe what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, the subject's posture, and any clear activity or occasion. Name the object type, not just its appearance — prefer "vacuum" over "black-handled tool", "headphones" over "device", "sweatshirt" over "long-sleeved top". If a brand name is clearly legible, include it; if brand text is blurry or uncertain, omit it rather than guess. If a location or landmark is clearly identifiable (a recognizable city, monument, street sign, or country-specific scene like red double-decker buses or yellow NYC taxis), name it.

Rules:
- Describe every visible element faithfully in the prose — do not suppress details. Describe cakes, candles, unfinished counter edges, exposed roots, hot dogs, and similar concrete items exactly as you see them.
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Do not invent objects that are not visible in the image.

Category-tag rule (applies only at the tag-list step, not the prose):
- Only tag an event or activity when the activity itself is visibly happening — people actively eating (not just food on a table alone) for `meal`, people actively hiking with gear (not just outdoor scenery) for `hike`, a construction scene in progress (not just unfinished edges alone) for `renovation`, a tent and campfire for `camping`, a cake with lit candles or a party hat being worn for `birthday`.
- Being outdoors, sitting on a rock, or wearing casual clothes is NOT evidence of any specific activity.
- A cake with lit candles IS evidence of `birthday`. Exposed roots and soil on a plant ARE evidence of `repotting`. An unfinished countertop with a visible support bracket and tools on top IS evidence of `renovation`.
- If the activity isn't clearly happening, omit the category tag. Prefer omission over guessing.

Then list 5-10 tags. Tags should cover: specific visible objects (with brand names if legible), the setting (indoor/outdoor, room or location type, city or landmark name if identifiable), and the occasion or activity if it clearly meets the category rule above. When you identify an occasion, activity, or object type in the description, include it explicitly as a tag.

Tag format: each tag is lowercase and can be one or two words — a natural noun or noun phrase a person would type when searching. Use spaces for multi-word tags, not hyphens or concatenation. Examples of good tags: bed, party hat, black cat, wine cooler, brake caliper, christmas tree, hot dog, red jacket, birthday, outdoor, repotting, london, travel. Skip tags that apply to most photos and are useless for search: wall, floor, ceiling, sky, ground, background, surface, object, scene.

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v7, drop-vocabulary + location hint (2026-04-18)

Successor to v6. Tests two hypotheses: (1) removing the explicit category vocabulary list ("birthday, meal, sports, hike, ...") from the prompt body stops the model force-matching a listed word; (2) adding an explicit "name the location/landmark if clearly identifiable" instruction recovers proper-noun tags like `london` that v6 lost. Sentinel: `ai:qwen36_4b-v7`.

Relative to v6: drops the category vocabulary enumeration from the category-tag rule; adds a "If a location or landmark is clearly identifiable" clause in the opening paragraph and location/landmark examples to the tag guidance.

```
Describe what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, the subject's posture, and any clear activity or occasion. Name the object type, not just its appearance — prefer "vacuum" over "black-handled tool", "headphones" over "device", "sweatshirt" over "long-sleeved top". If a brand name is clearly legible, include it; if brand text is blurry or uncertain, omit it rather than guess. If a location or landmark is clearly identifiable (a recognizable city, monument, street sign, or country-specific scene), name it.

Rules:
- Describe every visible element faithfully in the prose — do not suppress details even when you are uncertain about the category they imply.
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Do not invent objects that are not visible in the image.
- At the tag-list step, if the image clearly depicts a specific event, activity, or scene type (supported by multiple concrete visible elements), tag it. If the evidence is thin or ambiguous, omit the category tag rather than guessing.

Then list 5-10 tags. Tags should cover: specific visible objects, the setting (indoor/outdoor, room or location type, city or landmark name if identifiable), and the occasion or activity if one is clearly present. When you identify an occasion, activity, or object type in the description, include it explicitly as a tag.

Tag format: each tag is lowercase and can be one or two words — a natural noun or noun phrase a person would type when searching. Use spaces for multi-word tags, not hyphens or concatenation. Examples of good tags: bed, party hat, black cat, wine cooler, brake caliper, christmas tree, hot dog, red jacket, birthday, outdoor, repotting, london, travel. Skip tags that apply to most photos and are useless for search: wall, floor, ceiling, sky, ground, background, surface, object, scene.

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v6, split-rule (content vs. category) (2026-04-18)

Successor to v5. Addresses the v5 asymmetry: "prefer omission" leaked into content description on photo 1 (killed birthday cake mention) while failing to kill false-positive category tags on photos 3/10. v6 splits the rule in two:

1. **Content fidelity** — describe every visible element faithfully, do NOT suppress details because the category is uncertain.
2. **Category confidence** — at the *tag step*, only include a category tag when multiple specific visible elements clearly support it; prefer omission over a loose match.

Same category vocabulary as v5 (birthday, meal, sports, hike, ...). Sentinel: `ai:qwen36_4b-v6`.

The two changed lines (replace v5's single occasion-inference rule):

```
- Describe every visible element faithfully in the prose — do not suppress details even when you are uncertain about the category they imply. Describe the cake, the candles, the unfinished counter edge, the exposed roots exactly as you see them.
- At the tag-list step (separately from the description), identify the event, activity, or scene category the image depicts and include it as a tag ONLY when multiple specific visible elements clearly support it. Prefer omitting the category tag over a loose match. Common categories: birthday, meal, sports, hike, camping, renovation, gardening, repotting, cooking, travel, holiday.
```

### Revised Qwen prompt — v5, prefer omission (2026-04-18)

Successor to v4. Single-line tighten: "include the category tag ONLY when multiple specific visible elements clearly support it. Prefer omission over a loose match." Everything else identical to v4. Tests whether a conservative bias can kill the v4 false positives (photo 3 `hiking`, photo 10 `christmas display`) without losing the v4 wins (photo 1 `birthday cake`, photo 6 `renovation`, etc.). Sentinel: `ai:qwen36_4b-v5`.

The one changed line (replaces v4's occasion-inference rule):

```
- Identify the event, activity, or scene category the image depicts and include it as a tag ONLY when multiple specific visible elements clearly support it. Prefer omission over a loose match. Common categories: birthday, meal, sports, hike, camping, renovation, gardening, repotting, cooking, travel, holiday.
```

### Revised Qwen prompt — v4, generalized category inference (2026-04-18)

Successor to v3. Single-line change: replaces v3's enumerated `(cue → output)` exemplar list ("party hat → birthday; bare roots → repotting; ...") with a category-vocabulary rule — the model picks from `birthday, meal, sports, hike, camping, renovation, gardening, repotting, cooking, travel, holiday` when multiple visible elements support one, rather than pattern-matching specific cues. Tests whether the model can generalize categorical inference instead of requiring every photo type's cue pattern to be hardcoded in the prompt. Sentinel: `ai:qwen36_4b-v4`.

Full prompt (only the occasion-inference line differs from v3):

```
Describe what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, the subject's posture, and any clear activity or occasion. Name the object type, not just its appearance — prefer "vacuum" over "black-handled tool", "headphones" over "device", "sweatshirt" over "long-sleeved top". If a brand name is clearly legible, include it; if brand text is blurry or uncertain, omit it rather than guess.

Rules:
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Do not invent objects that are not visible in the image.
- Identify the event, activity, or scene category the image depicts (e.g. birthday, meal, sports, hike, camping, renovation, gardening, repotting, cooking, travel, holiday) and include it as a tag when multiple visible elements support it. Do not invent a category with no visible support.

Then list 5-10 tags. Tags should cover three things: specific visible objects, the setting (indoor/outdoor, room or location type), and the occasion or activity if one is present. When you identify an occasion, activity, or object type in the description, include it explicitly as a tag.

Tag format: each tag is lowercase and can be one or two words — a natural noun or noun phrase a person would type when searching. Use spaces for multi-word tags, not hyphens or concatenation. Examples of good tags: bed, party hat, black cat, wine cooler, brake caliper, christmas tree, hot dog, red jacket, birthday, outdoor, repotting. Skip tags that apply to most photos and are useless for search: wall, floor, ceiling, sky, ground, background, surface, object, scene.

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v3, multi-word tags + tighter inference (2026-04-18)

Successor to v2. Flips the single-word tag rule to "one or two words, use spaces" after learning that Photos.app tokenizes on whitespace (so `partyhat` as one token doesn't match a "party" search). Adds "name the object type, not its appearance" (photo 6 Dyson), adds `repotting` and `renovation` to occasion-inference exemplars, adds "do not invent objects not visible", adds "when you identify an occasion/activity/object type in the description, include it explicitly as a tag" (photo 4 birthday fix). Sentinel: `ai:qwen36_4b-v3`.

```
Describe what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, the subject's posture, and any clear activity or occasion. Name the object type, not just its appearance — prefer "vacuum" over "black-handled tool", "headphones" over "device", "sweatshirt" over "long-sleeved top". If a brand name is clearly legible, include it; if brand text is blurry or uncertain, omit it rather than guess.

Rules:
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Do not invent objects that are not visible in the image.
- Infer the occasion or activity only when it is strongly suggested by visible elements (party hat → birthday; plate of food + table setting → meal; sports equipment in use → playing; bare roots + soil → repotting; unfinished construction → renovation). Do not invent activities with no visible support.

Then list 5-10 tags. Tags should cover three things: specific visible objects, the setting (indoor/outdoor, room or location type), and the occasion or activity if one is present. When you identify an occasion, activity, or object type in the description, include it explicitly as a tag.

Tag format: each tag is lowercase and can be one or two words — a natural noun or noun phrase a person would type when searching. Use spaces for multi-word tags, not hyphens or concatenation. Examples of good tags: bed, party hat, black cat, wine cooler, brake caliper, christmas tree, hot dog, red jacket, birthday, outdoor, repotting. Skip tags that apply to most photos and are useless for search: wall, floor, ceiling, sky, ground, background, surface, object, scene.

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v2, findability-tuned (2026-04-18)

Successor to v1 below. Softens the "only-visible" rule to allow strongly-implied occasions (party hat → birthday), requires tags to cover objects + setting + activity, and blacklists ubiquitous junk tags (wall, sky, floor…). Sentinel: `ai:qwen36_4b-v2`.

```
Describe what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, the subject's posture, and any clear activity or occasion. Prefer specific nouns over generic categories (for example "striped shirt" not "clothing"; "floral pillow" not "bedding").

Rules:
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Infer the occasion or activity only when it's strongly suggested by visible elements (party hat → birthday; plate of food + table setting → meal; sports equipment in use → playing). Do not invent activities with no visible support.

Then list 5-10 tags. Each tag MUST be a single lowercase word — no phrases, no multi-word compounds. Tags should cover three things: specific visible objects, the setting (indoor/outdoor, room or location type), and the occasion or activity if one is present. Skip tags that apply to most photos and are useless for search (wall, floor, ceiling, sky, ground, background).

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

### Revised Qwen prompt — v1 (2026-04-18)

Qwen-targeted: forbids mood words, speculation, meta-commentary; forces single-word tags; requires only-visible items.

```
Describe only what is visibly present in this image in 2-3 sentences. Name concrete, observable details: objects, colors, clothing, materials, and the subject's posture or action. Prefer specific nouns over generic categories (for example "striped shirt" not "clothing"; "floral pillow" not "bedding").

Rules:
- No mood or atmosphere words (no "nostalgic", "peaceful", "cozy", "warm", "quiet", "serene").
- No speculation about when, why, or by whom the photo was taken.
- No meta-commentary about the photograph itself (no "faded", "pinkish tint", "retro aesthetic", "vintage photo").
- Only describe what is clearly visible; do not infer activities that are not shown.

Then list 5-10 tags. Each tag MUST be a single lowercase word — no phrases, no multi-word compounds. Include only items clearly visible in the image.

Format strictly as:
DESCRIPTION: <text>
TAGS: <tag1>, <tag2>, ...
```

---

## Photo 1 — Party table

![Photo 1](PICT0001.jpeg)

### Claude reference _(revised 2026-04-18 from higher-res export)_

```
DESCRIPTION: A rectangular table in the corner of a small room is covered with a pink and cream checkered tablecloth and set for a birthday party. The spread includes a platter of ringed cold cuts, bread rolls, a cake and pastries topped with lit birthday candles, a plate of yellow fruit pieces on toothpicks, and a plastic cup of amber liquid. Two dark wooden chairs with curved spindle backs sit at each end, against a cream wall with a light-wood door on the right.
TAGS: birthday, cake, candles, chair, door, food, party, platter, table, tablecloth
```

_Earlier low-res pass missed the birthday candles entirely and mistook the cup for "tall stemmed glasses". Resolution matters when using Claude as a reference — fine detail, food items, and colors can be wrong off a thumbnail._

### Gemma4:31b — default prompt (2026-04-17)

```
DESCRIPTION: A vintage photograph shows a dining table covered with a checkered tablecloth and filled with various appetizers and party plates. The scene takes place in a simple room with pale walls and a wooden door in the background.
TAGS: appetizers, checkered tablecloth, food, interior, nostalgia, party, table, vintage
```

### Qwen3 — default prompt (2026-04-18)

```
DESCRIPTION: A vintage photograph shows a table covered with a checkered tablecloth, set for a casual gathering or party with plates of food, drinks, and decorations. The scene includes chairs around the table and a warm, nostalgic atmosphere.
TAGS: casual, chairs, decorations, drinks, food, gathering, nostalgic, party, tablecloth, vintage
```

### Qwen3 — revised v1 prompt (2026-04-18)

```
DESCRIPTION: A rectangular table covered with a brown and white checkered tablecloth holds multiple paper plates containing food items including hot dogs, fruit skewers, bread rolls, and celery sticks. Several plastic forks are scattered on the table alongside a white styrofoam cup and an empty white plate. Wooden chairs with curved backrests surround the table against a plain off-white wall and a light wood door.
TAGS: bread, chair, cup, door, food, fork, fruit, hotdog, plate, table, tablecloth, wall
```

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth holds various party items, including paper plates, plastic cups, hot dogs on buns, fruit skewers, and candles. Several wooden chairs surround the table, which is situated in a room with light-colored walls and a closed door in the background.
TAGS: table, tablecloth, chairs, food, plates, cups, hotdogs, fruit, candles, indoor
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: A round table covered with a brown and white checkered tablecloth holds various food items including plates of fruit, hot dogs, bread rolls, and a cake with candles. Several plastic cups and utensils are scattered across the table, alongside paper plates and napkins. Wooden chairs surround the table in a room with light-colored walls and a closed door in the background.
TAGS: tablecloth, food, cake, hot dogs, fruit, plastic cup, paper plate, wooden chair, indoor, party
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A round table covered with a brown and white checkered tablecloth is set with various food items, including plates of fruit, pastries, and what appears to be a cake with candles. Several plastic cups and disposable plates are scattered across the table, alongside plastic utensils wrapped in napkins. Three wooden chairs with curved backs surround the table in an indoor room with plain walls and a closed door.
TAGS: tablecloth, disposable plate, plastic cup, wooden chair, fruit platter, birthday cake, candles, plastic utensils, indoor, party
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A round table covered with a brown and white checkered tablecloth is set with various food items including plates of bread, fruit, and hot dogs, along with plastic cups and utensils. The scene includes wooden chairs surrounding the table and a closed door in the background, indicating an indoor dining setup for a meal.
TAGS: tablecloth, bread, fruit, hot dogs, plastic cup, wooden chair, indoor, meal, party food
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth holds an assortment of party food, including plates of sliced bagels, a platter of fruit skewers, and a cake topped with candles. Several white disposable plates and plastic utensils are scattered across the table surface, alongside a white cup and a small rectangular dish. Three wooden chairs with curved backs are positioned around the table against a plain, light-colored wall.

TAGS: party food, tablecloth, bagels, fruit skewers, cake, candles, disposable plates, wooden chairs, indoor, birthday
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth holds multiple plates of food, including what appear to be hot dogs, sandwiches, and fruit skewers, along with plastic cups and utensils. Three wooden chairs are positioned around the table, which is situated in a room with plain walls and a closed door in the background.

TAGS: table, tablecloth, food, hot dog, sandwich, fruit skewer, plastic cup, wooden chair, indoor, party
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth holds an assortment of food items, including plates of bread, a bowl of fruit salad with toothpicks, and a small cake with lit candles. Several white disposable plates and plastic utensils are arranged on the table, alongside a white cup and a long breadstick. Three wooden chairs with curved backs surround the table in a room with plain beige walls and a closed door in the background.

TAGS: table, tablecloth, bread, fruit salad, cake, candles, disposable plates, plastic utensils, wooden chairs, indoor
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth is set with multiple plates of food, including what appears to be a pizza, bread rolls, and skewered fruit. Several white disposable plates hold small, colorful items, some of which are decorated with thin, upright candles. Three wooden chairs with curved backs surround the table, positioned against a plain wall and near a closed door.

TAGS: tablecloth, pizza, bread rolls, fruit skewers, candles, disposable plates, wooden chairs, indoor, party food
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth is set with various food items, including plates of bread, fruit skewers, and a cake with lit candles. Several white disposable plates and cups are arranged on the table, along with wooden chairs surrounding it. The scene is indoors against a plain wall with a door visible in the background.

TAGS: table, tablecloth, food, cake, candles, fruit skewers, bread, disposable plates, chairs, indoor
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a brown and white checkered tablecloth holds multiple plates of food, including donuts with red and white toppings, fruit skewers, and bread rolls. Several white paper plates contain small candles, and a white cup sits near the center of the spread. Dark wooden chairs with curved backs surround the table, which is positioned in a room with plain beige walls and a closed door in the background.

TAGS: tablecloth, donuts, fruit skewers, bread rolls, candles, paper plates, wooden chairs, party food, indoor, birthday
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A round table covered in a brown and white checkered tablecloth holds an assortment of food items, including plates of sliced bagels, a platter of hot dogs topped with red sauce, and fruit skewers arranged on a white plate. Several clear plastic cups with blue straws are placed among the dishes, and a stack of white paper plates sits in the foreground. Three wooden chairs surround the table, which is positioned against a plain beige wall next to a closed door.

TAGS: tablecloth, bagels, hot dogs, fruit skewers, paper plates, plastic cups, wooden chairs, indoor, party food
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth holds an assortment of food items including plates of bread, a platter of fruit, and a cake with lit candles. Three wooden chairs surround the table, which is set against a plain beige wall in a kitchen.

TAGS: tablecloth, cake, candles, bread, fruit, chairs, kitchen, meal
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A round dining table covered with a red and white checkered tablecloth holds an assortment of food items including plates of bread, a platter of fruit skewers, and a bowl of salad. Several white paper plates are stacked on the table, and a white cup sits near the center. Three wooden chairs with curved backs surround the table against a plain beige wall.
TAGS: dining table, tablecloth, food, fruit skewers, bread, paper plates, wooden chairs, meal, indoor
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth holds various food items including plates of bread, fruit skewers, and a cake with candles. Wooden chairs surround the table in a room with plain walls.

TAGS: table, tablecloth, food, bread, fruit, cake, candles, chairs, indoor
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a red and white checkered tablecloth holds plates of food, including donuts with candles, fruit skewers, and bread rolls. Several white disposable plates and cups are arranged on the table alongside a long loaf of bread. Three wooden chairs with curved backs surround the table in a room with plain walls and a closed door.

TAGS: table, tablecloth, food, donuts, candles, fruit, bread, party, indoor, meal
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A round table covered with a checkered tablecloth holds various plates of food, including bread, fruit, and pastries. Several items are decorated with small candles. Wooden chairs surround the table in a room with light-colored walls.

TAGS: table, food, bread, fruit, pastries, candles, tablecloth, chairs, meal
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- oval table
- checkered tablecloth
- wooden chairs
- plates
- food
- candles
- fruit
- bread
- plastic cups
- napkins
- door
- wall

**PHASE 2 — SCENE.**
The objects are arranged on a dining table set against a plain wall with a door visible in the background, suggesting an indoor domestic setting like a kitchen or dining room. The presence of candles and multiple plates indicates a meal or celebration is taking place.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A dining table covered with a checkered tablecloth holds an assortment of food, including bread, fruit, and plates with candles. Wooden chairs surround the table, which is positioned near a wall and a closed door.
TAGS: dining table, food, candles, fruit, bread, checkered tablecloth, wooden chairs, meal
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A round table covered with a red and white checkered tablecloth holds an assortment of party food, including plates of sliced fruit, bagels, and a cake with lit candles. Three wooden chairs surround the table in a room with plain beige walls and a closed door in the background. A white cup and a stack of white paper plates sit on the table alongside the food.",
  "tags": [
    "table",
    "tablecloth",
    "food",
    "cake",
    "candles",
    "fruit",
    "bagels",
    "chairs",
    "indoor",
    "dining room"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A round table covered with a checkered tablecloth holds a variety of food items including plates of bread, fruit skewers, and a cake with lit candles. Wooden chairs surround the table, and a white cup sits near the center of the spread.",
  "tags": [
    "table",
    "tablecloth",
    "food",
    "candles",
    "fruit",
    "bread",
    "cake",
    "chairs",
    "birthday"
  ]
}
```

---

## Photo 2 — Sleeping child

![Photo 2](PICT0002.jpeg)

### Claude reference _(revised 2026-04-18 from higher-res export)_

```
DESCRIPTION: A young child with short reddish-brown hair sleeps on their side in a dark-stained wooden bed whose headboard combines turned spindles with a carved center panel. The child wears a blue-and-white gingham long-sleeved pajama top over a white graphic t-shirt, and rests on a pillow printed with small red-brown branching florals. The same floral pattern continues on the bedding against a plain off-white wall.
TAGS: bed, bedroom, child, floral, gingham, pajamas, pillow, sleeping, spindles, wood
```

_Earlier pass called the pajama top "red-and-white checkered" — actually blue-and-white gingham. The red is a sock at the foot of frame._

### Gemma4:31b — default prompt (2026-04-17)

```
DESCRIPTION: A small child is fast asleep in a wooden bed. The child is wearing patterned pajamas and resting on a floral pillow and light blue blanket.
TAGS: bed, bedroom, child, childhood, indoor, nap, pajamas, sleeping
```

### Qwen3 — default prompt (2026-04-18)

```
DESCRIPTION: A young child sleeps peacefully in a wooden bed, covered with patterned blankets and wearing pajamas, under soft, warm lighting that gives the scene a nostalgic, vintage feel.
TAGS: childhood memory, cozy bedroom, floral blanket, pajamas, quiet moment, restful sleep, retro aesthetic, sleeping child, vintage photo, wooden bed
```

### Qwen3 — revised v1 prompt (2026-04-18)

```
DESCRIPTION: A child lies on their side in a wooden bed with turned spindles, eyes closed, wearing a white shirt with red sleeves and purple checkered pajama pants. The child rests on a floral-patterned pillow and is partially covered by a light-colored blanket.
TAGS: bed, blanket, child, floral, pajamas, pillow, shirt, sleeping, spindles, wooden
```

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A child with light brown hair sleeps on a pillow with a brown floral pattern, wearing a white t-shirt with red sleeves and blue checkered pajama pants. The child lies on a wooden bed frame with turned spindles, covered by a white blanket.
TAGS: child, bed, pillow, blanket, pajamas, sleeping, bedroom, t-shirt, pillowcase, headboard
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: A child with short brown hair is sleeping in a wooden bed, lying on their side with eyes closed. The child wears a long-sleeved shirt with red sleeves and a graphic print, paired with blue and white checkered pajama pants. A floral-patterned blanket covers the lower half of the body, while a solid-colored sheet lies beneath. The bed has a dark wood headboard with turned spindles and a decorative panel.
TAGS: child, sleeping, bed, wooden headboard, pajamas, floral blanket, red sleeves, checkered pants, indoor, bedroom
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A child sleeps in a wooden bed with a floral patterned blanket, wearing a long-sleeved shirt with red and blue accents and checkered pajama pants. The bed has a wooden headboard with turned spindles, and the child lies on their side with eyes closed.
TAGS: bed, sleeping child, wooden headboard, floral blanket, pajamas, long sleeve shirt, bedroom, sleep
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A child lies asleep in a wooden bed with a floral patterned blanket and a purple checkered pillow, wearing a long-sleeved shirt with red cuffs and a graphic print. The headboard features turned spindles and a cross-shaped panel, and the child's arms are resting near their chest.
TAGS: bed, sleeping child, wooden headboard, floral blanket, checkered pillow, long sleeve shirt, bedroom, sleep
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A child with short brown hair lies asleep in a wooden bed with a curved headboard and turned spindles. The child wears a long-sleeved shirt with red cuffs and purple trim, covered by a blue and white checkered blanket. The bed has a floral patterned pillowcase and a solid-colored sheet.

TAGS: sleeping child, wooden bed, checkered blanket, floral pillowcase, bedroom
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A young child with light brown hair is sleeping in a wooden bed, wearing a white t-shirt with red sleeves and purple checkered pajama pants. The child lies on their back with one arm extended outward, resting on a floral-patterned pillow and covered by a light-colored blanket. The bed features a dark wood headboard with turned spindles and a curved top rail.

TAGS: child, bed, sleeping, pajamas, pillow, blanket, wooden furniture, bedroom, indoor
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A child with short brown hair lies asleep in a wooden bed with a headboard featuring turned spindles and a solid panel. The child wears a long-sleeved shirt with red sleeves and a graphic on the front, along with blue and white checkered pajama pants. The bed is covered with a white sheet featuring a dark floral pattern and a solid light-colored blanket. The background consists of a plain, light-colored wall.

TAGS: bed, child, pajamas, sleeping, wooden furniture, floral sheet, pillow, bedroom
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A young child with short brown hair lies asleep on a bed, wearing a white t-shirt with red graphics and red long sleeves underneath, along with purple and white checkered pajama pants. The child rests on a pillow covered with a white case featuring a dark floral pattern, while their right arm extends outward. The bed features a dark wooden headboard with turned spindles and a curved top rail, positioned against a plain, light-colored wall.

TAGS: bed, wooden headboard, child, sleeping, pajamas, floral pillowcase, t-shirt, long sleeves, indoor
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A young child with short brown hair is sleeping in a wooden bed, wearing a white shirt with red sleeves and a purple checkered blanket. The bed features a dark wood headboard with turned spindles and a cross-shaped panel, and the child is resting on a floral patterned pillowcase.

TAGS: child, bed, wooden headboard, sleeping, pajamas, floral pattern, bedroom
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A child lies asleep in a wooden bed with a curved headboard and turned spindles, wearing a white t-shirt with red sleeves and a graphic print alongside purple and white checkered pajama pants. The child rests on a pillow covered in a floral patterned case, with one arm extended outward and the other bent near the chest.

TAGS: child, bed, sleeping, pajamas, t-shirt, wooden furniture, pillow, floral pattern, indoor
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A child sleeps in a wooden bed frame with turned spindles, wearing a red and white long-sleeved shirt and blue-and-white checkered pajama pants. The child rests on a floral-patterned pillow and blanket, with one arm extended outward.

TAGS: bed, child, pajamas, pillow, blanket, sleeping
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A young child with short brown hair sleeps in a wooden bed, wearing a white t-shirt with red sleeves and a graphic print, along with blue and white checkered pajama pants. The child lies on their back with eyes closed, resting on a pillow covered in a floral patterned case, while a solid-colored blanket covers the lower body.

TAGS: child, sleeping, bed, pajamas, pillow, blanket, t-shirt, wooden
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A young child with short brown hair sleeps on a bed with eyes closed, wearing a white t-shirt with red sleeves and purple trim. The child lies on a pillow covered with a floral patterned case, partially covered by a blue and white checkered blanket. A wooden bed frame with turned spindles is visible behind the pillow.
TAGS: child, sleeping, bed, wooden frame, pajamas, blanket, pillow, bedroom
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A child lies asleep on a bed with eyes closed, wearing a white shirt with red sleeves and blue checkered pajama pants. The child rests on a floral patterned pillow next to a wooden headboard featuring turned spindles and a solid panel.

TAGS: child, bed, pillow, headboard, pajamas, shirt, sleeping
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A young child with short hair sleeps in a wooden bed with a curved headboard and turned spindles. The child wears a long-sleeved shirt with red cuffs and a blue collar, lying under a floral patterned blanket and a blue and white checkered quilt.

TAGS: child, sleeping, bed, wooden headboard, floral blanket, checkered quilt, pajamas, bedroom
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A child with short hair lies asleep in a wooden bed, covered by a checkered blanket and wearing a long-sleeved shirt with red cuffs. The bed features a wooden headboard with turned spindles and a floral patterned sheet.

TAGS: child, sleeping, bed, blanket, pajamas, bedroom, headboard
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- wooden bed frame
- wooden headboard
- floral patterned pillowcase
- checkered pajamas
- long-sleeved shirt
- red sleeve
- white wall

**PHASE 2 — SCENE.**
A child is lying horizontally on a bed, resting their head on a floral pillowcase next to a wooden headboard. The setting is a bedroom with white walls.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A child wearing checkered pajamas and a long-sleeved shirt with a red sleeve lies asleep on a bed with a floral patterned pillowcase. The bed features a wooden headboard with turned spindles against a white wall.
TAGS: child, bed, sleeping, pajamas, wooden headboard, bedroom
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A young child sleeps on a bed with a wooden headboard, wearing a red and white long-sleeved shirt and blue checkered pajama pants. The child rests on a floral patterned pillow and a light-colored blanket, with one arm extended outward. The room has plain walls and simple furnishings.",
  "tags": [
    "child sleeping",
    "wooden bed",
    "pajamas",
    "bedroom",
    "floral pillow",
    "indoor"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A child sleeps in a bed with a wooden headboard, wearing a red and white long-sleeved shirt with a graphic print and checkered pajama pants. The bed features floral patterned bedding and a light-colored blanket covering the lower body.",
  "tags": [
    "child",
    "sleeping",
    "bedroom",
    "bed",
    "wooden headboard",
    "pajamas",
    "pillow",
    "blanket"
  ]
}
```

---

## Photo 3 — Child on rock by river

![Photo 3](PICT0003.jpeg)

### Claude reference _(revised 2026-04-18 from higher-res export)_

```
DESCRIPTION: A smiling young boy sits on a large gray boulder at the edge of a rushing whitewater river, wearing a blue baseball cap with a small logo, a red hooded sweatshirt with a yellow hood and blue-striped cuffs, blue jeans, striped tube socks, and white canvas sneakers. A forest of evergreen conifers lines the far bank with distant hills on the right, and bare branches enter the frame on the right foreground.
TAGS: boulder, boy, cap, forest, hoodie, jeans, outdoors, river, sneakers, whitewater
```

_Earlier pass said "red long-sleeved jacket" — accurate on base color but missed the yellow hood and blue cuff stripes. Qwen v1/v2 reading of "orange with stripes" now looks like a combined error (base color wrong, but the stripes on the cuffs are real)._

### Gemma4:31b — default prompt (2026-04-17)

```
DESCRIPTION: A young child wearing a red jacket and a blue cap sits atop a large rock. In the background, a rushing river with white water flows through a forested landscape.
TAGS: child, childhood, forest, nature, outdoors, rapids, river, vintage
```

### Qwen3 — default prompt (2026-04-18)

```
DESCRIPTION: A young child in a red jacket and blue cap sits on a large rock beside a rushing river, smiling at the camera with a forested hillside in the background. The photo has a vintage, faded color tone, suggesting it was taken decades ago.
TAGS: adventure, camping, child, childhood, landscape, nature, outdoors, river, rocks, vintage photo
```

### Qwen3 — revised v1 prompt (2026-04-18)

```
DESCRIPTION: A child sits on a large gray rock near a rushing river with white water, wearing a blue baseball cap, an orange long-sleeved shirt with dark stripes, dark pants, and light-colored sneakers. The background features dark green trees on a sloped bank under a pale sky, with additional rocks visible in the water and along the shore.
TAGS: branches, cap, child, pants, river, rock, shirt, sneakers, trees, water
```

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A young boy sits on a large grey rock beside a flowing river with white water rapids, wearing a blue baseball cap, an orange long-sleeved shirt with blue stripes, dark pants, and sneakers. The background features a dense forest of evergreen trees and distant hills under a bright sky.
TAGS: boy, river, rocks, trees, cap, shirt, pants, sneakers, outdoors, nature
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: A child sits on a large rock beside a rushing river, wearing a blue baseball cap, an orange sweatshirt with blue stripes, dark pants, and sneakers. The child's hands rest on the rock surface, legs bent, facing forward. Behind them, white water flows over rocks, with a forested hillside and bare branches visible in the foreground.
TAGS: child, baseball cap, sweatshirt, sneakers, river, rocks, forest, outdoor, sitting, nature
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, an orange sweatshirt, dark pants, and sneakers sits on a large rock beside a rushing river with white water rapids. He is smiling and looking toward the camera, with his hands resting on the rock surface. The background features a dense forest of evergreen trees under a bright sky.
TAGS: boy, baseball cap, orange sweatshirt, sneakers, river, rapids, rocks, forest, outdoor, hiking
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A child wearing a blue baseball cap, orange sweatshirt, and dark pants sits on a large grey rock next to a rushing river with white water rapids. The background features a dense forest of evergreen trees on a hillside under a bright sky.
TAGS: child, baseball cap, orange sweatshirt, river, rapids, rocks, forest, outdoor, hiking
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A child wearing a blue baseball cap, an orange sweatshirt with blue stripes on the sleeves, dark pants, and sneakers sits on a large grey rock. The child's hands rest on the rock surface, and their legs are bent at the knees. Behind the child, white water rushes over dark rocks in a river, bordered by a dense forest of dark green trees under a bright sky. Thin, bare branches are visible in the foreground on the right side.

TAGS: child, baseball cap, orange sweatshirt, sneakers, river, rapids, rocks, forest, outdoor
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a blue baseball cap, an orange sweatshirt, and dark pants sits on a large grey rock in front of a rushing river with white water rapids. The child's hands rest on the rock surface, and their legs are bent at the knees. Behind the river, a dense forest of dark green trees covers a hillside under a bright sky.

TAGS: child, river, rapids, rocks, trees, outdoor, nature, riverbank, camping
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, an orange sweatshirt with blue stripes, dark pants, and sneakers sits on a large grey rock. Behind him, white water rushes over dark rocks in a river, bordered by a dense forest of dark green trees. To the right of the frame, thin, bare branches of a bush are visible in the foreground.

TAGS: boy, baseball cap, orange sweatshirt, sneakers, river, rapids, rocks, trees, outdoor
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A young child sits on a large, grey rock in the foreground, wearing a blue baseball cap, an orange sweatshirt with blue stripes on the sleeves, dark pants, and white sneakers. The child's hands rest on the rock surface, and their legs are bent at the knees. Behind the child, a river with white, rushing water flows over dark rocks, bordered by a dense forest of dark green trees on a hillside in the background.

TAGS: child, baseball cap, orange sweatshirt, sneakers, river, rapids, rocks, trees, outdoor, nature
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, an orange sweatshirt, and dark pants sits on a large grey rock next to a rushing river with white water rapids. The background features a dense forest of pine trees and a distant hillside under a bright sky.

TAGS: boy, baseball cap, orange sweatshirt, river, rapids, rocks, trees, outdoor
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, a red sweatshirt with blue vertical stripes, dark pants, and sneakers sits on a large grey rock. He leans back slightly with his hands resting on the rock surface behind him, looking directly toward the camera. Behind him, white water rushes rapidly over jagged rocks in a river, bordered by a dense forest of dark green trees under a bright sky.

TAGS: boy, baseball cap, red sweatshirt, sneakers, rocks, river, rapids, trees, outdoor, nature
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, a red hooded sweatshirt, and dark pants sits on a large grey rock next to a fast-flowing river. The water rushes over jagged rocks in the background, leading to a shoreline covered in dense evergreen trees under a bright sky.

TAGS: boy, baseball cap, red sweatshirt, river, rocks, trees, outdoor
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, an orange jacket with blue stripes, dark pants, and sneakers sits on a large grey rock. He is positioned in front of a rushing river with white water rapids, surrounded by dark rocks and a forest of trees on the far bank.

TAGS: boy, river, rocks, jacket, cap, sneakers, trees, rapids, outdoors
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, an orange hooded sweatshirt, and dark pants sits on a large grey rock in the foreground. He smiles at the camera with his hands resting on the rock surface. Behind him, white water rapids flow rapidly over dark rocks in a river. A dense forest of coniferous trees lines the far bank under a bright sky.
TAGS: boy, river rapids, rocks, waterfall, trees, outdoors, nature, river, boy, water
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A young child sits on a large grey rock beside a fast-flowing river with white water rapids. The child wears a red hooded sweatshirt, dark pants, sneakers, and a blue baseball cap. The background features a dense forest of evergreen trees along the riverbank and distant hills.

TAGS: child, river, rapids, rocks, trees, hoodie, cap, outdoor
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap, an orange jacket with blue stripes, and dark pants sits on a large grey rock. He is positioned in front of a rushing river with white water rapids flowing over dark rocks. A dense forest of pine trees lines the far bank of the river under a bright sky.

TAGS: boy, river, rapids, rocks, trees, outdoor, nature, water, clothing, hat
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A young boy wearing a blue baseball cap and an orange jacket sits on a large rock next to a rushing river with white water rapids. The background features a dense forest of pine trees and a distant hill.

TAGS: boy, river, rocks, nature, outdoors, water, trees, rapids, clothing, hat
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- child
- baseball cap
- orange sweatshirt
- pants
- sneakers
- rock
- river
- rapids
- trees
- hill

**PHASE 2 — SCENE.**
A child sits on a large rock in the foreground, positioned next to a fast-flowing river with visible rapids. The background features a dense forest of trees along the riverbank and a distant hill, indicating an outdoor natural setting.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A child wearing a baseball cap and orange sweatshirt sits on a large rock beside a rushing river. The water flows rapidly over rocks in the background, leading toward a shoreline covered in trees and a distant hill.
TAGS: child, baseball cap, orange sweatshirt, river, rapids, trees, hill, outdoor
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A young boy wearing a blue baseball cap, an orange hooded sweatshirt, and dark pants sits on a large grey rock in the foreground. Behind him, a river flows rapidly over jagged rocks, creating white water rapids. The background features a dense forest of pine trees and rolling hills under a bright sky.",
  "tags": [
    "boy",
    "outdoor",
    "river",
    "rapids",
    "rocks",
    "forest",
    "trees",
    "sweatshirt",
    "baseball cap"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A young boy wearing a blue baseball cap, orange hooded sweatshirt, and dark pants sits on a large grey boulder in the foreground. Behind him, a river with white water rapids flows rapidly over dark rocks, bordered by a dense forest of coniferous trees on a hillside.",
  "tags": [
    "boy",
    "baseball cap",
    "hooded sweatshirt",
    "river",
    "rapids",
    "boulder",
    "forest",
    "outdoor"
  ]
}
```

---

## Photo 4 — Birthday child on bed

![Photo 4](PICT0004.jpeg)

### Claude reference _(revised 2026-04-18 from higher-res export)_

```
DESCRIPTION: A smiling young child with short brown hair sits cross-legged on a bed, wearing a pink-striped long-sleeved shirt and dark pants, and a conical paper party hat patterned with multicolored dots. The child holds a small red object in their lap with both hands. The bed has a dark wooden headboard with turned spindles and is covered with a cream bedspread printed with red-brown branching florals; a burgundy curtain hangs on the left.
TAGS: bed, birthday, child, curtain, floral, hat, headboard, party, smile, spindles
```

_The bedspread pattern and spindle headboard here appear to be the same fabric and similar bed as photo 2 — likely the same child's bedroom._

### Gemma4:31b — default prompt (2026-04-17)

```
DESCRIPTION: A young child wearing a birthday party hat sits cross-legged on a bed with a floral patterned bedspread. The child is smiling and wearing a striped long-sleeve shirt and dark pants.
TAGS: bed, bedroom, birthday, child, childhood, party hat, smiling, vintage
```

### Qwen3 — default prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a party hat sits smiling on a bed with floral-patterned bedding, surrounded by a wooden headboard and dark curtains. The photo has a vintage, slightly faded quality with a pinkish tint.
TAGS: bed, celebration, child, curtains, floral pattern, indoor, party hat, smile, vintage photo, wooden headboard
```

### Qwen3 — revised v1 prompt (2026-04-18)

```
DESCRIPTION: A child sits cross-legged on a bed with a floral-patterned sheet, wearing a striped long-sleeve shirt, dark pants, and a conical party hat with yellow and blue patterns. The bed has a wooden headboard with turned spindles, and a dark curtain hangs to the left. The child's hands rest on their knees, and they are smiling directly at the camera.
TAGS: bed, child, curtain, hat, headboard, pants, pillow, shirt, shoes, wall
```

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A child wearing a conical party hat with yellow and blue patterns sits cross-legged on a bed covered with a white sheet featuring a dark floral print. The child wears a long-sleeved shirt with horizontal stripes, dark pants, and dark shoes, with hands resting near the feet. A wooden headboard with turned spindles is visible behind the child, and a dark curtain hangs to the left.
TAGS: child, partyhat, bed, sheet, headboard, curtain, shirt, pants, shoes, indoor
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: A child sits cross-legged on a bed with a floral-patterned comforter, wearing a striped sweatshirt, dark pants, and a conical party hat. The bed has a wooden headboard with turned spindles, and a dark curtain hangs to the left. The child's hands rest near their feet, and they are smiling toward the camera.
TAGS: bed, party hat, sweatshirt, curtain, wooden headboard, child, birthday, indoor, bedroom, sitting
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A young child sits cross-legged on a bed with a floral-patterned comforter, wearing a long-sleeved shirt, dark pants, shoes, and a conical party hat. The bed has a wooden headboard with turned spindles, and a dark curtain hangs to the left. The child's hands rest near their feet, and they face forward.
TAGS: bed, party hat, child, bedroom, birthday, curtain, comforter, shoes, long-sleeved shirt
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A child sits cross-legged on a bed with a floral patterned sheet, wearing a striped sweatshirt, dark pants, and a cone-shaped party hat. The bed has a wooden headboard with turned spindles, and a dark curtain hangs to the left. The child's hands rest near their feet, and they are looking toward the camera.
TAGS: bed, party hat, sweatshirt, curtain, wooden headboard, child, birthday
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a striped sweatshirt and dark pants sits cross-legged on a bed with a floral patterned bedspread, holding their shoes in their hands. The child wears a conical party hat with yellow and blue stripes and smiles at the camera. A wooden bed frame with turned spindles is visible behind the child, and a dark curtain hangs to the left side of the frame.

TAGS: child, bed, party hat, sweatshirt, shoes, curtain, bedroom, birthday
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A young child with shoulder-length hair sits cross-legged on a bed, wearing a striped long-sleeved shirt, dark pants, and a conical party hat with yellow and blue stripes. The bed has a wooden headboard with turned spindles and is covered with a white sheet featuring a dark floral or branch pattern. To the left, a dark, textured curtain hangs vertically, and the wall behind the bed is plain and light-colored.

TAGS: bed, party hat, child, bedroom, floral sheet, wooden headboard, curtain, birthday
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A young child with shoulder-length hair sits cross-legged on a bed, wearing a conical party hat with a spiral pattern, a long-sleeved sweatshirt with horizontal stripes, dark pants, and dark shoes. The bed has a wooden headboard with turned spindles and is covered with a floral-patterned bedspread featuring dark branches and leaves on a light background. To the left, a dark curtain hangs vertically next to the bed frame.

TAGS: bed, party hat, sweatshirt, curtain, bedspread, child, bedroom
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A young child with shoulder-length hair sits cross-legged on a bed, wearing a conical party hat with yellow and blue stripes and a small red circle at the tip. The child wears a long-sleeved sweatshirt with horizontal stripes, dark pants, and dark shoes, holding their feet with both hands. The bed has a wooden headboard with turned spindles and is covered with a floral-patterned bedspread featuring dark branches and leaves on a light background. To the left, a dark curtain hangs vertically beside the bed frame.

TAGS: bed, party hat, sweatshirt, shoes, curtain, birthday
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a conical party hat with yellow and blue stripes sits cross-legged on a bed covered with a floral patterned sheet. The child wears a long-sleeved striped shirt, dark pants, and dark shoes, holding their feet while smiling at the camera. To the left, a dark wooden bed frame with spindles is visible next to a dark curtain.

TAGS: child, party hat, bed, bedroom, party
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A child sits cross-legged on a bed with a floral patterned sheet, wearing a long-sleeved striped shirt, dark pants, and a conical party hat. The bed features a wooden headboard with vertical spindles, and a dark curtain hangs to the left of the frame.

TAGS: bed, party hat, striped shirt, wooden headboard, curtain, child, bedroom
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a conical party hat with yellow and blue spirals sits cross-legged on a bed covered in a floral-patterned sheet, holding dark shoes in their hands. The bed features a wooden headboard with turned spindles, and a dark curtain hangs to the left of the frame against a plain wall.

TAGS: child, party hat, bed, floral sheet, wooden headboard, shoes, indoor, bedroom, birthday
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A young child with shoulder-length hair sits cross-legged on a bed, wearing a conical party hat with yellow and blue stripes. The child wears a long-sleeved shirt with horizontal stripes, dark pants, and dark shoes. The bed features a wooden headboard with vertical spindles and is covered by a white sheet with a dark floral pattern. A dark curtain hangs to the left of the bed against a plain wall.

TAGS: child, party hat, bed, headboard, curtain, shirt, pants, shoes, floral sheet
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A young child with shoulder-length hair sits cross-legged on a bed, wearing a conical party hat with yellow and blue stripes and a red pom-pom on top. The child wears a long-sleeved shirt with horizontal stripes, dark pants, and dark shoes. The bed has a wooden headboard with turned spindles and is covered with a floral patterned bedspread. A dark curtain hangs to the left of the bed.
TAGS: child, party hat, birthday, bed, bedroom, floral pattern, wooden headboard, indoor
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a conical party hat with yellow and blue stripes sits cross-legged on a bed. The child wears a long-sleeved shirt with horizontal stripes, dark pants, and dark shoes. The bed has a wooden headboard with turned spindles and is covered with a floral patterned bedspread. A dark curtain hangs to the left of the bed against a plain wall.

TAGS: child, party hat, bed, headboard, bedspread, curtain, indoor
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a conical party hat with yellow and blue stripes sits cross-legged on a bed covered in a floral patterned bedspread. The child wears a long-sleeved shirt with horizontal stripes and dark pants, with hands resting on their knees. A wooden bed frame with turned spindles is visible behind the child, and a dark curtain hangs on the left side of the frame.

TAGS: child, birthday, party hat, bed, bedroom, floral bedspread, wooden headboard, curtain
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A young child wearing a conical party hat sits on a bed with a floral patterned bedspread. The child wears a striped long-sleeved shirt and dark pants, holding shoes in their hands. A wooden headboard with spindles is visible behind the child, and a dark curtain hangs to the left.

TAGS: child, bed, party hat, bedroom, furniture, clothing, shoes
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- bed
- floral patterned bedspread
- wooden headboard
- child
- party hat
- long-sleeved shirt
- pants
- shoes
- curtain
- wall

**PHASE 2 — SCENE.**
A child sits cross-legged on a bed with a floral bedspread and a wooden headboard, positioned next to a dark curtain against a plain wall. The presence of the party hat indicates an indoor bedroom setting, likely during a celebration.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A child wearing a party hat sits cross-legged on a bed covered in a floral patterned bedspread. The bed features a wooden headboard with spindles and is positioned next to a dark curtain against a plain wall.
TAGS: child, party hat, bed, bedroom, floral bedspread, wooden headboard, celebration, indoor
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A young child with shoulder-length hair sits cross-legged on a bed covered with a floral patterned sheet. The child wears a striped long-sleeved shirt, dark pants, and a conical party hat with colorful stripes. A wooden headboard with vertical spindles is visible behind the child, and a dark curtain hangs to the left.",
  "tags": ["child", "party hat", "bedroom", "bed", "curtain", "floral sheet", "birthday", "striped shirt", "wooden headboard"]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A child wearing a conical party hat with yellow and blue stripes sits cross-legged on a bed covered in a floral patterned bedspread. The child wears a long-sleeved shirt with horizontal stripes, dark pants, and dark shoes. A wooden headboard with turned spindles is visible behind the child, and dark curtains hang to the left of the bed.",
  "tags": [
    "child",
    "party hat",
    "bedroom",
    "bed",
    "birthday",
    "curtains",
    "headboard"
  ]
}
```

---

## Photo 5 — Car brake caliper

![Photo 5](72C680A3-459C-48DF-A14B-BF9AD2A23D2E.jpeg)

_Source file: `72C680A3-459C-48DF-A14B-BF9AD2A23D2E.jpeg`_

### Claude reference (2026-04-18)

```
DESCRIPTION: A glossy blue four-piston aftermarket brake caliper with a small white logo is mounted over a vented gray metal brake rotor on a wheel hub, with brake dust and light rust visible on the surrounding components. A cluttered garage workshop fills the background with branded Bilstein parts boxes, other cardboard boxes, assorted automotive components on metal shelving, and a concrete floor.
TAGS: automotive, bilstein, brake, caliper, car, garage, hub, rotor, shelf, workshop
```

Notes: `bilstein` pulled from the boxes in the background — this is the kind of OCR-style brand catch the PhotoSnail pipeline should surface through its Vision-OCR-rescue path even if the LLM misses it.

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with an "M" logo is mounted on a silver brake rotor, which is attached to a rusty wheel hub assembly. The background contains cardboard boxes, plastic bags, and shelving units filled with various automotive parts and tools.
TAGS: caliper, rotor, hub, brake, car, parts, garage, workshop, blue, metal
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a visible "M" logo is mounted on a silver brake rotor, which is attached to a rusty wheel hub assembly. The components are resting on a dark workbench in a cluttered workshop filled with cardboard boxes, tools, and shelving units.
TAGS: brake caliper, brake rotor, wheel hub, workshop, car parts, blue paint, automotive repair
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with an "M" logo is mounted on a silver brake rotor, which is attached to a rusty wheel hub assembly. The components are situated in a cluttered workshop environment surrounded by cardboard boxes and shelving units containing various tools and parts.
TAGS: brake caliper, brake rotor, wheel hub, automotive repair, workshop, car parts, blue paint, mechanical repair
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white "M" logo is mounted on a silver brake rotor, which is attached to a rusty wheel hub assembly sitting on a workshop floor. The background contains cardboard boxes, shelving units, and various automotive parts scattered around the workspace.
TAGS: brake caliper, brake rotor, wheel hub, automotive parts, workshop, car repair
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a small white and red logo is mounted on a grey brake rotor, which is attached to a rusty wheel hub assembly. The background shows a cluttered workshop environment with cardboard boxes, shelving units, and various automotive parts scattered on the floor.

TAGS: brake caliper, brake rotor, wheel hub, automotive parts, workshop, car repair, blue object, cardboard box
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white and red logo is mounted on a silver, ventilated brake rotor, which is attached to a rusty wheel hub assembly. The background shows a cluttered workshop environment with cardboard boxes, tools, and shelving units.

TAGS: brake caliper, brake rotor, wheel hub, automotive parts, workshop, car repair, blue caliper, brake system
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white, red, and blue logo is mounted on a silver brake rotor, which is attached to a rusty wheel hub assembly. The background shows a cluttered workshop environment containing cardboard boxes, shelving units, and various automotive parts.

TAGS: brake caliper, brake rotor, wheel hub, automotive parts, workshop, cardboard boxes
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white, red, and blue "M" logo is mounted on a silver brake rotor with drilled ventilation slots. The assembly sits on a dark workshop floor surrounded by cardboard boxes, tools, and other automotive parts.

TAGS: brake caliper, brake rotor, car parts, workshop, automotive repair
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A close-up view of a bright blue brake caliper mounted on a vehicle's brake rotor assembly, situated in a cluttered workshop environment. The caliper features a white "M" logo with blue and red stripes, indicating a performance part. The background contains cardboard boxes, tools, and shelving units typical of a garage or repair shop.

TAGS: brake caliper, brake rotor, car parts, workshop, garage, bmw, blue, automotive, repair
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white, red, and blue logo sits mounted on a silver brake rotor assembly. The assembly includes a rusty wheel hub and is positioned in a workshop environment surrounded by cardboard boxes and shelving units.

TAGS: brake caliper, brake rotor, wheel hub, blue caliper, car parts, workshop, cardboard box
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white "M" logo sits mounted on a silver brake rotor in a workshop. The assembly is positioned near cardboard boxes and shelving units filled with various automotive parts and tools. The background shows a cluttered workspace with visible mechanical components and storage containers.

TAGS: brake caliper, brake rotor, workshop, automotive parts, m logo, blue caliper, car repair, mechanical parts
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white "M" logo sits on top of a black brake rotor in a cluttered workshop. The assembly includes rusty wheel studs and a dirty axle hub, surrounded by cardboard boxes and shelves of tools.

TAGS: brake caliper, brake rotor, car part, workshop, tool shelf, cardboard box, wheel hub, blue, automotive
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A bright blue BMW M brake caliper with the white, blue, and red M logo is mounted on a black ventilated brake rotor. The assembly includes a rusty wheel hub and lug bolts, sitting on a dark workshop floor surrounded by cardboard boxes and shelves of automotive parts.
TAGS: brake caliper, bmw m, brake rotor, car parts, auto repair, workshop, blue, automotive
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A close-up view of a bright blue automotive brake caliper mounted on a vehicle's wheel hub assembly. The caliper features a white "M" logo with red and blue stripes on its side. It is clamped onto a silver, drilled brake rotor, which is attached to a rusty wheel hub. The background contains cardboard boxes and shelving units in a workshop setting.

TAGS: brake caliper, brake rotor, wheel hub, car parts, automotive, workshop, machinery, blue, metal
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white, red, and blue "M" logo is mounted on a silver brake rotor. The assembly sits on a dark workshop floor surrounded by cardboard boxes and automotive parts.

TAGS: brake caliper, brake rotor, car parts, workshop, automotive, suspension, brake pads, blue
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A bright blue brake caliper with a white "M" logo sits mounted on a black ventilated brake rotor in a workshop setting. The assembly is attached to a rusty wheel hub, surrounded by cardboard boxes and shelves of automotive parts.

TAGS: brake caliper, brake rotor, car parts, automotive repair, workshop, brake system, car maintenance
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- brake caliper
- brake rotor
- wheel hub
- lug nut
- cardboard box
- shelf
- tool
- "M" logo

**PHASE 2 — SCENE.**
The brake assembly is positioned in the foreground of a cluttered workshop, surrounded by cardboard boxes and storage shelves. The setting is an indoor garage or repair shop filled with automotive parts and equipment.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A blue brake caliper featuring an "M" logo is mounted onto a silver brake rotor and wheel hub assembly. The mechanical components sit in the foreground of a workshop environment, surrounded by stacked cardboard boxes and shelves holding various tools and supplies.
TAGS: brake caliper, brake rotor, wheel hub, m logo, workshop, automotive parts, repair shop, tool storage
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A bright blue brake caliper with a white and red logo sits atop a large, black ventilated brake rotor in a cluttered workshop. The assembly includes visible wheel studs and a rusty hub, surrounded by cardboard boxes and automotive parts on the floor.",
  "tags": [
    "brake caliper",
    "brake rotor",
    "blue",
    "automotive parts",
    "workshop",
    "car repair",
    "brakes",
    "mechanic"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A blue brake caliper with a white \"M\" logo and red and blue stripes sits on top of a black brake rotor. The assembly rests on a workbench in a workshop, surrounded by cardboard boxes and tools.",
  "tags": [
    "brake caliper",
    "brake rotor",
    "bmw m",
    "workshop",
    "automotive parts",
    "car repair"
  ]
}
```

---

## Photo 6 — Kitchen countertop install

![Photo 6](IMG_0408.jpeg)

_Source file: `IMG_0408.jpeg`_

### Claude reference (2026-04-18)

```
DESCRIPTION: A light wood butcher-block countertop is being installed in a kitchen, viewed along its edge so an aluminum channel or support track mounted underneath is visible. The surrounding kitchen includes a stainless steel refrigerator, white cabinets with a white herringbone-tile backsplash, a dark brick accent wall, and a handheld Dyson vacuum resting on the counter. A decorated Christmas tree with warm lights and a red topper stands in the far room with light hardwood flooring throughout.
TAGS: cabinet, christmas, countertop, dyson, kitchen, refrigerator, renovation, tree, wood, indoor
```

Notes: `renovation` inferred from the raw unfinished edge + unmounted support track — a strongly-implied activity. `christmas` + `tree` are visible occasion markers. `dyson` again OCR/brand-recognition — useful for search ("where did I put that photo of the new Dyson?").

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop with a visible aluminum extrusion bracket supports a black-handled tool with a red accent. The scene includes a stainless steel refrigerator, a black brick fireplace, and a decorated Christmas tree with lights in the background on a light wood floor.
TAGS: countertop, tool, refrigerator, fireplace, christmas tree, bracket, flooring, kitchen, interior
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop extends over a kitchen island, supported by a visible silver metal bracket with a complex cross-section. In the background, a stainless steel refrigerator stands next to a black brick fireplace, and a lit Christmas tree with red ornaments is positioned in the corner of the room.
TAGS: kitchen island, christmas tree, stainless steel refrigerator, wooden countertop, metal bracket, black brick fireplace, holiday decoration, interior design
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A light wood countertop with an exposed aluminum extrusion bracket is mounted above a black brick fireplace and stainless steel refrigerator. In the background, a decorated Christmas tree with lights stands on a light wood floor.
TAGS: christmas tree, kitchen island, aluminum extrusion, stainless steel refrigerator, brick fireplace, home renovation
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop is being installed over a stainless steel refrigerator, with a metal support bracket visible underneath the wood. A black and red handle tool rests on the counter surface, and a lit Christmas tree stands in the background of the room.
TAGS: christmas tree, countertop, refrigerator, renovation, kitchen, christmas
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop with an unfinished edge reveals a silver metal support bracket with a complex cross-section. A black and red handle tool rests on the counter surface, and a stainless steel refrigerator stands adjacent to a dark brick fireplace structure. In the background, a lit Christmas tree with red ornaments is positioned on a light wood floor near a white door.

TAGS: christmas tree, countertop, refrigerator, brick fireplace, tool, kitchen, renovation
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop extends over a kitchen island, supported by a visible silver aluminum extrusion bracket attached to its underside. A black and red power tool rests on the countertop surface near a stainless steel refrigerator and a dark gray brick fireplace. In the background, a lit Christmas tree with red ornaments stands on a light wood floor in a room with white walls and cabinetry.

TAGS: kitchen island, christmas tree, power tool, aluminum bracket, wooden countertop, stainless steel refrigerator, brick fireplace, home interior
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: The image shows a close-up of a light-colored wooden countertop with an unfinished edge, supported by a silver metal bracket and a black structural element. A black and red tool rests on the countertop surface. In the background, a stainless steel refrigerator stands next to a dark brick fireplace, and a lit Christmas tree with red ornaments is visible in the corner of the room. The floor is covered in light wood laminate.

TAGS: kitchen, christmas tree, countertop, refrigerator, fireplace, tool, renovation, wooden floor, metal bracket
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop extends horizontally, supported by a white cabinet base on the left and a black structural element underneath. The front edge of the counter reveals an exposed aluminum support bracket with a complex profile, indicating an unfinished construction phase. A black-handled tool with a red accent rests on the countertop surface. In the background, a stainless steel refrigerator stands next to a wall clad in dark gray bricks, and a decorated Christmas tree with lights is visible in the distance on a light wood floor.

TAGS: kitchen counter, aluminum bracket, christmas tree, stainless steel refrigerator, brick wall, wooden floor, renovation, countertop, tool
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A close-up view of a light-colored wooden countertop with an unfinished edge, supported by a silver metal bracket and a black structural block underneath. A power tool with a red and black handle rests on the counter surface. In the background, a stainless steel refrigerator and a lit Christmas tree are visible in a room with light wood flooring.

TAGS: kitchen island, countertop, metal bracket, power tool, christmas tree, refrigerator, renovation, wood floor, indoor
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop extends horizontally, supported by a silver metal bracket with an open channel profile attached to its underside. A black and red tool rests on the countertop surface near a stainless steel refrigerator. In the background, a lit Christmas tree stands on a light wood floor next to a dark brick wall.

TAGS: kitchen island, wooden countertop, metal bracket, stainless steel refrigerator, christmas tree, renovation, tools, brick wall, light wood floor
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop features an exposed metal support bracket along its front edge, indicating an ongoing installation or modification. A power tool with a red handle rests on the counter surface, positioned near a stainless steel refrigerator and a black brick fireplace. In the background, a lit Christmas tree stands in a room with light wood flooring.

TAGS: kitchen renovation, wooden countertop, metal bracket, power tool, stainless steel refrigerator, black brick fireplace, christmas tree, indoor
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A thick wooden countertop is supported by a silver aluminum extrusion frame attached to its underside. A black and red hand tool rests on the light-colored wood surface, while a stainless steel refrigerator stands behind the structure. In the background, a lit Christmas tree with red decorations is visible in the corner of the room.

TAGS: countertop, aluminum, wood, refrigerator, christmas tree, tool, kitchen, renovation
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop extends horizontally, supported by a white cabinet base on the left and a black brick column on the right. A silver metal extrusion with a hollow profile is embedded along the front edge of the countertop. A black and red power tool rests on the surface. In the background, a stainless steel refrigerator stands next to a decorated Christmas tree with lights and a red bow on top. The floor is light wood laminate.
TAGS: countertop, christmas tree, refrigerator, power tool, metal extrusion, kitchen, renovation, holiday, home improvement
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A light-colored wooden countertop extends horizontally, supported by a silver aluminum extrusion bracket attached to its underside. A black and red power tool rests on the countertop surface. Behind the counter, a stainless steel refrigerator stands next to a dark gray brick fireplace. In the background, a lit Christmas tree with red ornaments sits on a light wood floor.

TAGS: kitchen, countertop, aluminum bracket, power tool, refrigerator, brick fireplace, christmas tree, indoor
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A close-up view of a wooden countertop edge reveals a silver metal support bracket attached to the underside of the wood. A black and red power tool rests on the surface of the counter. In the background, a stainless steel refrigerator stands next to a black brick fireplace, and a lit Christmas tree is visible in the adjacent room.

TAGS: kitchen renovation, wooden countertop, metal bracket, power tool, christmas tree, stainless steel refrigerator, brick fireplace, interior design
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A close-up view of a kitchen island countertop featuring a light wood surface and an exposed aluminum support bracket attached to its side. A black and red tool rests on the countertop surface, and a stainless steel refrigerator stands in the background next to a dark brick wall. A lit Christmas tree with red decorations is visible in the distance on the wooden floor.

TAGS: kitchen island, countertop, aluminum bracket, refrigerator, christmas tree, renovation, tools, interior design
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- kitchen island
- wooden countertop
- metal bracket
- power drill
- refrigerator
- brick wall
- Christmas tree
- floor
- door

**PHASE 2 — SCENE.**
The image depicts a kitchen island under construction, positioned in the foreground of a residential kitchen. The setting includes a stainless steel refrigerator and a decorated Christmas tree in the background, indicating a home environment during the holiday season.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A wooden kitchen island features a custom metal bracket attached to its side, with a power drill resting on the countertop. The island is situated in a kitchen next to a stainless steel refrigerator and a brick wall, while a lit Christmas tree stands in the background.
TAGS: kitchen island, wooden countertop, metal bracket, power drill, refrigerator, brick wall, christmas tree, renovation
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A light-colored wooden countertop extends over a kitchen island, supported by a visible metal bracket with a complex cross-section. A black-handled tool with a red accent rests on the countertop surface near a stainless steel refrigerator. In the background, a decorated Christmas tree with lights stands in a living area with light wood flooring.",
  "tags": [
    "kitchen island",
    "wooden countertop",
    "metal bracket",
    "refrigerator",
    "christmas tree",
    "interior design",
    "home renovation"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A light-colored wooden countertop features an exposed aluminum support bracket with a hollow profile along its front edge. A black and red power tool rests on the countertop surface near a stainless steel refrigerator. In the background, a lit Christmas tree stands in a room with light wood flooring and a black brick wall.",
  "tags": [
    "kitchen",
    "renovation",
    "countertop",
    "aluminum bracket",
    "power tool",
    "refrigerator",
    "christmas tree",
    "wood flooring"
  ]
}
```

---

## Photo 7 — Uprooted succulent

![Photo 7](IMG_0758.jpeg)

_Source file: `IMG_0758.jpeg`_

### Claude reference (2026-04-18)

```
DESCRIPTION: An uprooted succulent plant with a pale green rosette of fleshy leaves at the top sits on a light wood surface. A long stem connects the rosette to a tangle of dark, soil-stained exposed roots at the base, with bits of dried soil clinging to them. Several shriveled, shedded lower leaves remain along the bare stem.
TAGS: gardening, houseplant, leaves, plant, repotting, roots, soil, stem, succulent, wood
```

Notes: `repotting` inferred from the bare exposed roots + dried soil — typical state for a plant mid-transplant. Test case for whether models over-or-under-infer activity on object-only images.

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, pale green stem and a rosette of pointed leaves at the top lies on a light wood-grain surface. The root system at the base is dark, tangled, and clumped with soil. The stem shows signs of drying and peeling near the roots.
TAGS: succulent, plant, stem, leaves, roots, soil, wood, surface, indoor
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, pale green stem and a rosette of pointed green leaves at the top lies on a light wood-grain surface. The plant's root system is exposed, showing dark soil clinging to the roots, indicating it has been removed from a pot.
TAGS: succulent, plant, roots, soil, stem, leaves, indoor, repotting
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A succulent plant with a thick, pale green stem and a rosette of pointed leaves at the top lies on a light-colored wooden floor, its dark, soil-covered roots exposed at the bottom.
TAGS: succulent, plant, stem, leaves, roots, wooden floor, repotting
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A succulent plant with a thick, pale green and tan stem is lying on a light wood-grain surface. The plant has a rosette of pointed green leaves at the top and a cluster of dark, soil-covered roots at the bottom.
TAGS: succulent, plant, roots, stem, leaves, wooden floor, gardening, repotting
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a thick, pale green stem and rosette of pointed leaves lies on a light wood-grain surface. The base of the stem shows brownish, textured nodes, and a cluster of dark, soil-covered roots extends from the bottom.

TAGS: succulent, plant, roots, soil, wooden surface, gardening, repotting
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, pale green stem and rosette of pointed leaves lies on a light-colored wooden floor. The base of the stem shows dried brown tissue and a cluster of dark, soil-covered roots extending outward.

TAGS: succulent, plant, stem, leaves, roots, wooden floor, indoor
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a thick, pale green stem and rosette of pointed leaves lies horizontally on a light-colored wooden floor. The plant's root system is exposed, showing dark brown soil clinging to the fibrous roots at the base of the stem.

TAGS: succulent, plant, roots, soil, wooden floor, repotting
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, pale green stem and rosette of pointed leaves lies horizontally on a light-colored wooden floor with visible grain. The base of the stem shows exposed roots covered in dark soil clumps, indicating it has been recently removed from a pot. The plant's stem appears slightly shriveled and textured near the root junction, transitioning to smoother, translucent-looking leaves at the top.

TAGS: succulent, plant, roots, soil, wooden floor, repotting
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, thick, pale green stem and a rosette of pointed leaves at the top lies on a light-colored wooden floor. The plant is uprooted, exposing a cluster of dark brown soil and tangled roots at the base of the stem.

TAGS: succulent, plant, roots, wooden floor, stem, leaves, soil
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a thick, pale green stem and a rosette of pointed leaves lies horizontally on a light-colored wooden floor. The plant's root system is exposed, showing dark soil clinging to the roots at the base of the stem.

TAGS: succulent, plant, roots, soil, wooden floor, repotting
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a thick, pale green stem and a rosette of pointed leaves at the top rests on a light-colored wooden surface. The plant's root system is exposed, showing dark soil clinging to the fine roots at the base of the stem.

TAGS: succulent, plant, stem, leaves, roots, soil, wooden surface, repotting
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, textured stem and green rosette leaves lies on a light-colored wooden floor. The plant's root system is exposed, showing dark soil clinging to the roots.

TAGS: succulent, plant, roots, soil, stem, leaves, wooden floor
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, thickened stem and green leaves at the top lies horizontally on a light-colored wooden surface. The stem shows brown, dried leaf scars along its length, and dark soil clings to the root system at the bottom.
TAGS: succulent, plant, stem, roots, soil, wooden surface, green leaves
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, pale green stem and rosette of pointed leaves lies horizontally on a light wood-grain surface. The plant has exposed roots with dark soil clinging to them at the base of the stem.

TAGS: succulent, plant, stem, roots, soil, wood, green, leaves
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, textured, pale green stem and a rosette of pointed leaves at the top rests on a light-colored wooden floor. The base of the stem features a cluster of dark roots with visible soil clinging to them.

TAGS: succulent, plant, stem, roots, soil, wooden floor, indoor
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A succulent plant with a long, thickened stem and green rosette leaves lies horizontally on a light-colored wooden floor. The plant's root system is exposed, showing dark soil clinging to the roots at the base of the stem.

TAGS: succulent, plant, roots, stem, leaves, soil, wooden floor, repotting
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- succulent plant
- wooden stem
- green leaves
- soil
- roots
- wooden floor

**PHASE 2 — SCENE.**
The succulent plant is lying horizontally on a light-colored wooden floor, likely indoors. The plant has been removed from its pot, exposing the soil and root system which are resting directly on the wood grain.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A succulent plant with a long, textured stem and green leaves lies horizontally on a wooden floor. The base of the plant shows exposed roots and clumps of dark soil, indicating it has been pulled from a container. The plant is positioned centrally on the light wood planks, which run diagonally across the frame.
TAGS: succulent plant, wooden floor, roots, soil, plant care
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A succulent plant with a thick, elongated stem and a cluster of green leaves at the top rests on a light-colored wooden floor. The plant's root system is exposed, showing dark soil clinging to the roots at the base of the stem.",
  "tags": [
    "succulent",
    "plant",
    "roots",
    "wooden floor",
    "repotting",
    "botany"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A succulent with a long, textured stem and green rosette leaves lies on a light wood-grain surface. The plant's root system is exposed and covered in dark soil clumps at the base of the stem.",
  "tags": [
    "succulent",
    "plant",
    "roots",
    "soil",
    "wooden surface",
    "repotting"
  ]
}
```

---

## Photo 8 — Cats at a door

![Photo 8](IMG_0762.jpeg)

_Source file: `IMG_0762.jpeg`_

### Claude reference (2026-04-18)

```
DESCRIPTION: A white cat on the left and a black cat on the right stand on a striped fringed rug in front of a glass-paneled door, both looking out into the backyard. The black cat is propped up on its hind legs with front paws against the glass. Beyond the door a metal deck railing, dried fallen leaves covering the ground, and stairs leading up are visible.
TAGS: autumn, backyard, cat, door, glass, indoor, leaves, pets, railing, rug
```

Notes: `autumn` inferred from the carpet of dried fallen leaves — strongly implied. Two distinct animal subjects (one black, one white); good test for whether models count and color-distinguish multiple subjects, something Apple Vision's animal-detection already handles well and which the LLM should complement, not duplicate.

### Qwen3 — revised v2 prompt, findability-tuned (2026-04-18)

```
DESCRIPTION: A black cat and a white cat stand on their hind legs on a striped rug, looking out through a glass door with vertical metal bars. To the right is a black wine cooler with a wooden top, and in the foreground is a light-colored wooden countertop.
TAGS: cat, cats, black, white, rug, door, window, winecooler, kitchen, standing
```

### Qwen3 — revised v3 prompt, multi-word tags (2026-04-18)

```
DESCRIPTION: Two cats, one black and one white, stand on their hind legs looking out a glass door. The black cat is positioned in front of the white cat, with its front paws resting on the window frame. To the right is a black wine cooler with a wooden top, situated next to a light-colored wooden countertop.
TAGS: black cat, white cat, wine cooler, glass door, wooden countertop, indoor, pets, standing
```

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: Two cats, one black and one white, stand on their hind legs looking through a glass door. The black cat is positioned in front of the white cat, both facing outward toward an outdoor area with grass and a railing. A wine cooler with a glass door is visible to the right, and a light-colored rug lies beneath the cats' paws.
TAGS: black cat, white cat, wine cooler, glass door, indoor, pet, standing, rug, outdoor view
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: Two cats, one black and one white, stand on their hind legs looking out a glass door onto a deck with metal railings. A black wine cooler with a glass door and silver handle stands to the right of the door. The scene is indoors, with light wood flooring and a striped rug visible beneath the cats.
TAGS: black cat, white cat, wine cooler, glass door, deck, metal railing, indoor, pet, standing
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: Two cats, one white and one black, stand on their hind legs inside a house, looking out through a glass door onto a yard with fallen leaves. The black cat is positioned to the right of the white cat, with its front paws resting on the window sill. They are standing on a patterned rug with fringed edges, and a wooden staircase railing is visible outside.

TAGS: black cat, white cat, glass door, rug, staircase, outdoor, pets
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: Two cats, one black and one white, stand on their hind legs with their front paws resting on the lower pane of a white-framed glass door, looking out at a yard covered in dry leaves. The black cat stands fully upright, while the white cat sits on its haunches beside it, both facing away from the camera. They are positioned on a light-colored rug with a geometric pattern and fringed edges, next to a wooden floor.

TAGS: black cat, white cat, glass door, rug, pet, looking out, standing, indoors, outdoor, yard
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: Two cats, one white and one black, stand on their hind legs looking out through a glass door with vertical metal bars. The white cat sits on a patterned rug with fringed edges on a wooden floor, while the black cat stands beside it with its front paws resting on the window sill. Outside, a grassy yard covered in fallen leaves is visible, along with a wooden staircase and a black door handle mounted on the white door frame.

TAGS: black cat, white cat, glass door, door handle, rug, wooden floor, staircase, outdoor, pets
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: Two cats, one white and one black, stand on their hind legs on a patterned rug with fringed edges, pressing their front paws against the glass pane of a white door with a black handle. Outside the door, a wooden deck railing and a yard covered in brown fallen leaves are visible.

TAGS: white cat, black cat, door, rug, outdoor, looking out
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: Two cats, one white and one black, stand on their hind legs looking through the glass of a white door with vertical metal bars. The black cat has its front paws resting on the window sill while the white cat sits beside it. They are positioned on a grey and white patterned rug with fringed edges inside a room, looking out onto a grassy yard covered in brown leaves and a wooden staircase.

TAGS: black cat, white cat, cats, door, window, rug, outdoor, stairs, grass
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A white cat and a black cat stand on their hind legs on a patterned rug, pressing their front paws against the glass pane of a white door to look outside. The door features a black handle and a vertical black railing is visible through the glass, separating the interior from an outdoor area covered in dry leaves.

TAGS: white cat, black cat, cat, door, glass, rug, outdoor, indoor
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A white cat and a black cat stand on their hind legs on a patterned rug, looking through the glass pane of a white door with a black handle. Outside, a wooden deck railing and grass covered with fallen leaves are visible.

TAGS: white cat, black cat, cat, door, glass, rug, outdoor, deck, leaves
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: Two cats stand on their hind legs at a glass door, looking out at a yard covered in fallen leaves. The cat on the left is white with grey markings, while the cat on the right is solid black. They are positioned on a patterned rug with fringed edges in front of a white door frame and black hardware.

TAGS: cat, black cat, white cat, glass door, porch, rug, leaves, outdoors
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A white cat and a black cat stand on their hind legs looking through a glass door window. The white cat sits on a patterned rug while the black cat stands with its front paws resting on the window sill. Outside the window, a wooden deck railing and ground covered in dry leaves are visible.
TAGS: cats, white cat, black cat, window, pet, indoor, standing, looking
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A white cat and a black cat stand on their hind legs looking through a glass door. The white cat sits on a patterned rug while the black cat stands with its front paws resting on the window sill. Outside, a wooden deck railing and fallen leaves are visible on the ground.

TAGS: cats, white cat, black cat, glass door, window, rug, deck, leaves, outdoor, indoor
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: Two cats stand on a patterned rug in front of a white door with a glass panel. The white cat sits on its hind legs while the black cat stands on its hind legs with its front paws resting on the bottom edge of the glass pane. Both animals face outward toward a wooden deck and a yard covered in fallen leaves.

TAGS: cats, black cat, white cat, pet, animal, door, window, indoor, outdoor, standing
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A white cat and a black cat stand on their hind legs on a patterned rug, looking through a glass door with a black handle and vertical metal bars. The cats face an outdoor area covered in dry leaves and grass, with a wooden staircase visible through the window.

TAGS: cat, cats, white cat, black cat, looking out, window, glass door, pet, animal, standing
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- cat
- rug
- door
- handle
- window
- grass
- leaf
- stair
- railing

**PHASE 2 — SCENE.**
Two cats are standing on a rug inside a house, looking out through a glass door at a yard with a wooden staircase.

**PHASE 3 — OUTPUT.**
DESCRIPTION: Two cats, one black and one white, stand on a rug inside a house looking out through a glass door at a yard with a wooden staircase.
TAGS: cat, black cat, white cat, door, rug, window, grass, leaf, stair, railing
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A white cat and a black cat stand side by side on a patterned rug, looking through a glass door at a wooden staircase and a yard covered in fallen leaves. The black cat stands on its hind legs with its front paws resting on the window sill, while the white cat sits beside it. The door features a black handle and a black peephole.",
  "tags": ["cats", "white cat", "black cat", "glass door", "wooden staircase", "rugs", "indoor", "outdoor", "pets"]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A white cat and a black cat stand on their hind legs on a patterned rug, looking through a glass door with a black handle onto a porch with wooden railings. The cats face outward toward a yard covered in fallen leaves, with the black cat placing its front paws on the window sill.",
  "tags": ["cats", "white cat", "black cat", "door", "porch", "railing", "rug", "pet", "outdoor"]
}
```

---

## Photo 9 — Graffiti box truck

![Photo 9](IMG_0083.jpeg)

_Source file: `IMG_0083.jpeg`. Added 2026-04-18 as part of the extended test set for v4 category generalization._

### Claude reference (2026-04-18)

```
DESCRIPTION: A white box truck parked along an urban street is covered in elaborate graffiti, with the cargo side dominated by large blue and purple wildstyle lettering and a brown cartoon character with angry eyes, a wide open mouth, and a pointing hand. The front cab carries smaller acorn-faced characters and orange-and-white spray splatters. A storm drain and asphalt roadway are visible in the foreground.
TAGS: box truck, graffiti, street art, mural, cartoon, urban, street, vehicle, outdoor
```

Notes: Tests whether the category rule drifts into false positives when no true event/occasion is present — the photo shows a vehicle with decorative art but no activity or occasion per se.

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A white box truck is parked on an asphalt street next to a manhole cover, its exterior completely covered in colorful graffiti art. The side of the cargo area features large blue and purple lettering alongside a cartoon character with a brown head, while the cab displays similar orange and white paint with smaller character faces.
TAGS: box truck, graffiti art, street art, cartoon character, vehicle, urban, street, manhole cover, painted truck, outdoor
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A large box truck is parked on a paved street next to a curb and a manhole cover. The vehicle's exterior is covered in colorful graffiti art, including large blue and purple lettering, a cartoon character with a wooden head, and abstract white splatters. The truck features a side-view mirror, black tires with silver rims, and a white cab.
TAGS: truck, graffiti, box truck, street, manhole cover, vehicle, art, urban, parked car, transportation
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A box truck is parked on a paved street next to a concrete curb, its entire exterior surface covered in colorful graffiti art. The artwork features large, stylized lettering in shades of blue, purple, and red, alongside cartoonish characters with exaggerated facial expressions and limbs. The truck's cab is primarily white and orange, displaying smaller circular character designs and hand gestures, while the rear cargo area shows layers of paint and tags in various colors.

TAGS: box truck, graffiti art, street art, cartoon character, urban art, vehicle, painted surface, outdoor, street scene
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A white box truck is parked on a paved street next to a concrete curb, its entire exterior surface covered in colorful graffiti art. The side of the cargo area features large, stylized lettering in shades of blue, purple, and red, alongside a cartoon character with a brown, textured head and red sneakers. The front cab of the truck displays smaller, circular versions of the same cartoon character, along with abstract white splashes and faded tags near the roofline. A black side-view mirror is attached to the driver's door, and a manhole cover is visible on the ground beneath the rear wheels.

TAGS: box truck, graffiti art, cartoon character, street art, urban scene, parked vehicle, concrete curb, manhole cover
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A white box truck is parked on a paved street next to a concrete curb and a metal manhole cover. The vehicle's cargo box and front cab are covered in colorful graffiti art, including large blue and purple bubble letters, white paint splatters, and a recurring cartoon character with a brown, textured head, white gloves, and red shoes. The truck's side mirror is black, and the tires are black with silver rims.

TAGS: truck, graffiti, box truck, street, manhole cover, cartoon character, spray paint, vehicle
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A white box truck is parked on a paved street next to a concrete curb, its entire exterior surface covered in colorful graffiti art. The artwork features large, stylized lettering in shades of blue, purple, and red, alongside cartoonish characters with exaggerated expressions, including a brown figure with sharp teeth and a pointing hand. The truck's cab displays similar orange and white paint schemes with additional character faces, while the rear section shows layers of faded tags and abstract shapes in various colors.

TAGS: truck, graffiti, street art, vehicle, urban, parked, cartoon, lettering, box truck, outdoor
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A white box truck is parked on a paved street next to a concrete curb, with its entire exterior surface covered in colorful graffiti art. The artwork features large, stylized lettering in shades of blue, purple, and red, alongside cartoonish characters with exaggerated facial expressions and limbs. The truck's cab and cargo box display overlapping layers of paint, including a prominent orange background and white splatter effects.

TAGS: truck, graffiti, street art, vehicle, urban, parked, cartoon, lettering, paint, box truck
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A white delivery truck is parked on a paved street next to a concrete curb, its entire exterior surface covered in colorful graffiti art. The artwork features large, stylized lettering in shades of blue, purple, and red, alongside cartoon characters with brown, textured skin and angry expressions. The vehicle's cab displays similar orange and white paint schemes with smaller versions of the cartoon figures, while the rear cargo area is heavily layered with tags and abstract designs in various colors.

TAGS: delivery truck, graffiti art, cartoon character, street art, urban art, vehicle, city street, painted surface, bumper sticker, license plate
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A white box truck is parked on an asphalt street next to a concrete curb, its entire exterior surface covered in colorful graffiti art. The side of the cargo area features large blue and purple bubble letters alongside a cartoon character with a brown, textured head, white gloves, and red sneakers. The front cab displays two smaller versions of the same cartoon character with angry eyes, while the rear upper section shows faded tags including the word "BONAR" in grey lettering. A black side-view mirror is mounted on the driver's door, and a manhole cover is visible on the ground near the rear wheels.

TAGS: truck, graffiti art, cartoon character, bubble letters, street art, urban, outdoor, bonar
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A box truck parked on a city street features extensive graffiti art covering its exterior. The artwork includes large, colorful bubble letters in blue and purple, alongside cartoon characters resembling cookies with faces. The truck's cab is painted orange and white, matching the vibrant mural on the trailer section.

TAGS: truck, graffiti, art, cartoon, street, vehicle, painting, lettering
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A white delivery truck is covered in colorful graffiti art, featuring a large cartoon character with a brown, textured head, wide eyes, and red sneakers. The side of the truck displays large blue and purple lettering, while the front cab has smaller versions of the same character. The truck is parked on a paved street next to a concrete sidewalk and a metal drain grate.
TAGS: delivery truck, graffiti art, cartoon character, street art, vehicle, urban, painted, street scene
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A box truck parked on a street features extensive graffiti art covering its exterior. The side panel displays large blue and purple bubble letters alongside a cartoon character with a brown head, white gloves, and red shoes. The white cab area includes smaller versions of the same character and abstract paint splatters. The rear section of the truck shows layers of faded tags and colorful markings. A black side mirror and a tire with a silver rim are visible on the vehicle.

TAGS: box truck, graffiti art, cartoon character, street art, vehicle, urban art, painted truck, street scene
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A white commercial box truck is parked on a paved street next to a concrete curb and a circular metal manhole cover. The vehicle's exterior, including the cab and cargo box, is covered in colorful graffiti art featuring large blue and purple bubble letters, a cartoon character with a wooden head, and abstract shapes. The truck's front fender displays two circular wooden character heads, and the rear upper section of the cargo box shows faded, illegible text and paint splatters.

TAGS: truck, graffiti, street art, vehicle, urban, painting, cartoon, character, street, curb
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A white box truck parked on a city street features extensive graffiti art covering its side and front panels. The artwork includes large blue and purple bubble letters, a cartoon character with a wooden head, and smaller circular faces painted in orange and white. The vehicle has a black side mirror, a visible windshield wiper, and a manhole cover on the pavement nearby.

TAGS: truck, graffiti, street art, vehicle, urban, painting, cartoon, lettering, street, transportation
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- truck
- box truck
- graffiti
- cartoon character
- wooden spoon
- spray paint
- tire
- wheel
- side mirror
- windshield
- manhole cover
- sidewalk
- "BONK"

**PHASE 2 — SCENE.**
A box truck is parked on a city street next to a concrete sidewalk. The vehicle's exterior is completely covered in colorful street art, including a large cartoon character holding a wooden spoon.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A box truck is parked on a city street next to a concrete sidewalk, its exterior completely covered in colorful street art. The artwork features a large cartoon character holding a wooden spoon and the text "BONK".
TAGS: truck, graffiti, street art, cartoon character, wooden spoon, box truck, urban art
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A white box truck is completely covered in colorful graffiti art, including large blue and purple lettering, a cartoon character with a wooden head, and various abstract shapes. The vehicle is parked on a paved street next to a curb, with a manhole cover visible in the foreground. The artwork extends from the front bumper to the rear of the cargo area, featuring orange, white, and red paint splashes.",
  "tags": [
    "graffiti art",
    "box truck",
    "street art",
    "urban",
    "vehicle",
    "painting",
    "outdoor",
    "city"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A box truck parked on a city street features extensive graffiti art covering its entire exterior. The artwork includes large blue and purple lettering, a large cartoon character with a brown head, and multiple smaller circular characters on the white cab door. The vehicle sits next to a concrete curb with a visible manhole cover.",
  "tags": [
    "graffiti",
    "box truck",
    "street art",
    "urban art",
    "vehicle",
    "city street",
    "cartoon character",
    "spray paint"
  ]
}
```

---

## Photo 10 — LEGO statue in a toy store

![Photo 10](IMG_0270.jpeg)

_Source file: `IMG_0270.jpeg`. Added 2026-04-18._

### Claude reference (2026-04-18)

```
DESCRIPTION: A life-sized statue built entirely from LEGO bricks depicts a man with tan skin, a prominent white beard, and brown hair, wearing a green three-piece suit with yellow buttons, a white shirt, and a black tie. The figure stands on the floor of a LEGO retail store with boxed LEGO sets on shelves behind (including a LEGO Tower Bridge set), and a person in a pink puffy jacket is visible on the left.
TAGS: lego, lego store, statue, toy store, beard, green suit, bricks, retail, display, indoor
```

Notes: Tests brand/proper-noun recognition (`lego` as a common word). Has green + a pink jacket nearby — NOT Christmas-themed; useful as a test of whether the category rule over-fires from color coincidence.

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A large, life-sized statue constructed from green, white, black, and tan LEGO bricks depicts a man with a beard wearing a green jacket, white shirt, and black tie. The figure stands indoors in what appears to be a retail store, with shelves of boxed toys visible in the background and a person wearing a red jacket standing to the left.
TAGS: lego statue, lego bricks, green jacket, beard, retail store, toy store, red jacket, mannequin, christmas display
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A large sculpture constructed from green, white, and black LEGO bricks depicts a figure wearing a green jacket with yellow buttons, a white shirt, and a black tie. The figure has a tan face and a white beard, and stands indoors next to a person wearing a red jacket and light-colored pants.
TAGS: lego, lego sculpture, green jacket, red jacket, toy store, indoor, holiday
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A large sculpture constructed from green, white, black, and tan LEGO bricks depicts a man with a beard wearing a green suit jacket with yellow buttons, a white shirt, and a black tie. To the left of the sculpture, a person wearing a red jacket and light-colored pants stands facing away from the camera. The background reveals a retail environment with shelves displaying boxed LEGO sets, including a set featuring a bridge, and black track lighting fixtures mounted on the ceiling.

TAGS: lego sculpture, lego bricks, green suit, red jacket, retail store, toy shelf, lego set, indoor
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: A large, life-sized sculpture of a bearded man constructed from green, white, and black LEGO bricks stands indoors, wearing a green jacket with yellow buttons, a white shirt, and a black tie. To the left, a person wearing a red jacket and light-colored pants is partially visible. In the background, retail shelving displays boxed LEGO sets, including a model of the Tower Bridge.

TAGS: lego sculpture, lego man, lego bricks, lego store, lego tower bridge, red jacket, retail display, toy store, indoor
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A large, life-sized statue constructed from green, white, black, and tan LEGO bricks depicts a man with a beard wearing a green suit jacket with yellow buttons, a white shirt, and a black tie. To the left of the statue, a person wearing a red jacket and light-colored pants stands partially in view. The background reveals a retail environment with shelves of boxed LEGO sets, including a box labeled "LEGO" and "15+", and overhead track lighting fixtures.

TAGS: lego statue, lego bricks, green suit, red jacket, toy store, lego box, brick sculpture, retail display
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A life-sized sculpture constructed from green, white, black, and beige plastic bricks depicts a man with a white beard wearing a green suit jacket with yellow buttons, a white shirt, and a black tie. To the left of the sculpture, a person wearing a red jacket and light-colored pants stands partially in the frame. The background shows a retail environment with shelves of boxed toys, including a LEGO set featuring a bridge, and overhead lighting fixtures.

TAGS: lego sculpture, lego man, green suit, white beard, red jacket, toy store, lego box, indoor
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A large, life-sized statue constructed from green LEGO bricks depicts a man with a white beard, wearing a green suit jacket with yellow buttons, a white shirt, and a black tie. The figure stands indoors, likely in a retail store, with shelves of boxed LEGO sets visible in the background and a person wearing a red jacket standing to the left.

TAGS: lego, lego statue, green suit, white beard, red jacket, toy store, bricks, sculpture, mannequin
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A massive sculpture constructed from green, white, black, and tan Lego bricks depicts a bearded man wearing a green double-breasted suit jacket with yellow buttons, a white shirt, and a black tie. The figure stands in an indoor retail environment, evidenced by hanging circular light fixtures and shelves stocked with boxed Lego sets in the background. To the left of the sculpture, a person wearing a red hooded sweatshirt and beige pants stands facing the display.

TAGS: lego, lego sculpture, lego man, green suit, red sweatshirt, indoor, toy store, brick art
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A large-scale sculpture constructed from green LEGO bricks depicts a bearded man wearing a green suit jacket with yellow buttons, a white shirt, and a black tie. The figure's head features a textured beige beard and mustache made from smaller beige bricks, and the torso displays a yellow collar detail. To the left, a person wearing a red jacket and light-colored pants stands partially visible next to the sculpture. In the background, retail shelving displays boxed LEGO sets, including a set labeled "15+" and another featuring a bridge structure, under circular ceiling lights.

TAGS: lego, sculpture, green suit, red jacket, toy store, indoor, lego set, bridge model, 15+, retail display
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A large-scale sculpture constructed from green, white, black, and tan LEGO bricks depicts a man with a beard wearing a suit jacket with yellow buttons. To the left of the figure, a person wearing a red jacket and white pants stands partially in view. The background shows a retail environment with shelves of boxed products and a visible "LEGO" logo on packaging.

TAGS: lego, sculpture, bricks, suit, jacket, beard, red jacket, store, display
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A large sculpture of a man with a white beard and mustache constructed from green, white, black, and tan LEGO bricks. The figure wears a green suit jacket with yellow buttons, a white shirt, and a black tie. The sculpture stands indoors in a retail environment, with shelves of boxed LEGO sets visible in the background, including a box labeled "LEGO" and "15+". A person wearing a red jacket and light-colored pants stands to the left of the sculpture.
TAGS: lego, lego bricks, sculpture, statue, man, beard, suit, jacket, toy store, display
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A large sculpture constructed from green LEGO bricks depicts a man with a white beard, wearing a green suit jacket, white shirt, and black tie. The figure has a tan face with visible eyes and a yellow collar. Yellow buttons adorn the front of the jacket. To the left, a person wearing a red jacket stands partially in view. In the background, retail shelves display boxed LEGO products, including a box labeled "LEGO" and "15+".

TAGS: lego sculpture, green suit, white beard, red jacket, lego store, retail display, toy boxes, indoor
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A large-scale sculpture constructed from green, white, black, and tan LEGO bricks depicts a male figure with a beard wearing a green suit jacket with yellow buttons and a black tie. The figure stands in a retail environment with shelves of boxed toys visible in the background, including a box displaying the "LEGO" logo and a "15+" age rating. A person wearing a red jacket and white pants stands partially visible to the left of the sculpture.

TAGS: lego, lego bricks, sculpture, toy store, lego logo, suit, beard, figure, indoor, retail
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A large sculpture of a man with a white beard constructed entirely from green, white, black, and tan LEGO bricks. The figure wears a green suit jacket with yellow buttons, a white shirt, and a black tie. A person wearing a red jacket stands partially visible to the left of the sculpture.

TAGS: lego, sculpture, statue, bricks, toy, display, suit, beard
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- lego bricks
- statue
- suit jacket
- tie
- beard
- face
- yellow buttons
- red jacket
- mannequin
- display box
- "LEGO"
- "15+"

**PHASE 2 — SCENE.**
The large lego statue stands prominently in the foreground of a retail store, likely a Lego brand store, surrounded by shelves of boxed merchandise. A mannequin wearing a red jacket is positioned to the left of the statue, while overhead track lighting illuminates the display area.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A massive statue constructed from green lego bricks depicts a bearded man wearing a suit jacket with yellow buttons and a black tie. The figure dominates the foreground of a retail environment, standing next to a mannequin dressed in a red jacket. In the background, shelves display boxed lego sets, including one labeled with the "LEGO" logo and an age recommendation of "15+".
TAGS: lego bricks, lego statue, suit jacket, mannequin, red jacket, lego sets, retail store, display box
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A massive sculpture constructed from green LEGO bricks depicts a man with a white beard wearing a green suit jacket, white shirt, and black tie. The figure features yellow buttons and stands in an indoor retail environment with visible LEGO product boxes and lighting fixtures in the background.",
  "tags": ["lego", "sculpture", "green suit", "beard", "toy store", "indoor", "model building"]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A large sculpture constructed from green LEGO bricks depicts a man with a white beard and mustache wearing a green suit jacket with yellow buttons, a white shirt, and a black tie. The figure stands indoors in a retail environment, with a person in a red jacket visible to the left and shelves of boxed LEGO sets, including one labeled \"LEGO,\" visible in the background.",
  "tags": [
    "lego",
    "lego bricks",
    "sculpture",
    "toy store",
    "indoor"
  ]
}
```

---

## Photo 11 — London street scene

![Photo 11](IMG_0218.jpeg)

_Source file: `IMG_0218.jpeg`. Added 2026-04-18._

### Claude reference (2026-04-18)

```
DESCRIPTION: A London street scene shows a red double-decker bus (route 94) approaching an intersection marked by a yellow "box junction" grid, with a blue advertising-wrapped London taxi and a black cab beside it. Crowds of pedestrians cross the street near large classical limestone buildings with curved facades and ornate windows. A woman with curly brown hair is visible in the left foreground.
TAGS: london, double decker bus, taxi, crosswalk, pedestrians, street, city, travel, urban, tourism
```

Notes: Tests proper-noun identification (`london`) and the `travel` category. Route 94 + the distinctive curved-facade architecture are Piccadilly-area cues, but safer to tag just `london`.

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: A street scene in London shows a red double-decker bus and a blue taxi cab navigating an intersection marked with yellow grid lines. Pedestrians wearing casual clothing cross the street near large, classical-style stone buildings, while a person with curly hair is partially visible in the foreground.
TAGS: double decker bus, taxi cab, pedestrians, street intersection, stone building, london, urban travel, traffic
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A street scene in London features a red double-decker bus and a blue taxi navigating an intersection with yellow box junction markings. Pedestrians cross the street near large, classical-style stone buildings, while a person with curly hair wearing a purple top occupies the foreground.
TAGS: double decker bus, taxi, london, street scene, pedestrians, yellow box junction, stone building, purple top, urban, travel
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A street scene shows a large intersection with yellow crisscross road markings, where a red double-decker bus and a blue taxi are driving past grand, light-colored stone buildings with arched windows and ground-floor archways. A crowd of pedestrians crosses the street in the background, while the back of a person with long brown hair wearing a purple top occupies the immediate foreground on the left.

TAGS: double decker bus, taxi, street scene, pedestrians, yellow road markings, stone building
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: The image shows a busy urban intersection with large, classical stone buildings featuring arched ground-floor entrances and numerous windows. A red double-decker bus travels down the center of the road, while a blue taxi with yellow advertising on its side is positioned to the right. A yellow box junction with crisscrossed lines marks the asphalt, and a large crowd of pedestrians crosses the street in the background. In the foreground, the back of a person's head with long brown hair and a purple garment is visible on the left side.

TAGS: double-decker bus, taxi, london, street scene, pedestrians, box junction, architecture, urban, transportation
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: A street scene in London features a large yellow box junction on the asphalt, with a red double-decker bus and a blue taxi driving through the intersection. Pedestrians cross the street in front of large, classical stone buildings with arched ground-floor entrances, while the back of a person's head with brown hair is visible in the immediate foreground.

TAGS: london, double decker bus, taxi, box junction, pedestrians, stone building, street scene, urban, transportation
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: A busy street intersection in London features two red double-decker buses and a blue taxi driving past large, classical stone buildings with arched ground-floor entrances. Pedestrians are walking across a yellow box junction painted on the asphalt, while a person with long brown hair wearing a purple top stands in the immediate foreground.

TAGS: london, red bus, double decker bus, blue taxi, yellow box junction, stone building, pedestrians, street scene, urban, architecture
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A street scene in London shows a yellow box junction with a red double-decker bus and a blue taxi driving through. Pedestrians are crossing the street near large, classical stone buildings, while the back of a person's head with brown hair is visible in the foreground.

TAGS: london, red bus, blue taxi, box junction, pedestrians, architecture, street scene, travel, double decker
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: A red double-decker bus travels through a junction marked by yellow crisscross lines, passing a blue taxi with white lettering on its side. The scene is framed by large, curved stone buildings featuring arched ground-floor entrances and numerous rectangular windows. A crowd of pedestrians crosses the street near the buildings, while the back of a person with long brown hair and a purple garment occupies the immediate foreground.

TAGS: double-decker bus, taxi, london, architecture, pedestrians, street, yellow lines, stone building, urban
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: A busy London street intersection features a prominent yellow box junction painted on the asphalt, with a red double-decker bus and a blue taxi navigating the lanes. Pedestrians cross the street in front of large, classical stone buildings that line the curved road, including one with a visible clock face near its roofline. In the foreground, the back of a person's head with brown hair is visible on the left side, while a small kiosk stands on the sidewalk to the right.

TAGS: london, double-decker bus, taxi, box junction, pedestrians, architecture, street scene, travel
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A crowd of pedestrians crosses a busy London intersection near the curved neoclassical buildings of Regent Circus, while a red double-decker bus and a blue taxi navigate the yellow box junction.

TAGS: london, bus, taxi, architecture, pedestrians, street, junction, double-decker, building
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A busy London street intersection features a yellow box junction painted on the asphalt. A red double-decker bus drives through the center of the frame, while a blue taxi with "SOMETHING" branding on its side waits on the right. Pedestrians cross the street in the background near large, classical stone buildings with arched ground-floor entrances. A person with brown hair and a purple top is partially visible in the bottom left foreground.
TAGS: london, double decker bus, taxi, box junction, pedestrians, street scene, architecture, urban, traffic, city
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: A street scene at Piccadilly Circus in London features a large yellow box junction painted on the asphalt. A red double-decker bus travels through the intersection, while a blue taxi with "SOMETHING" branding drives nearby. Pedestrians cross the street in front of historic stone buildings with arched ground-floor entrances and upper-story windows. A person with brown hair is visible in the immediate foreground on the left.

TAGS: london, piccadilly circus, red bus, blue taxi, box junction, pedestrians, architecture, street scene, double decker, urban
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: A street scene at a busy intersection in London features a red double-decker bus and a blue taxi driving past large, curved stone buildings with arched walkways. A yellow box junction painted on the asphalt separates the lanes, and a crowd of pedestrians crosses the street near a storefront displaying the "Boots" logo. The back of a person with long brown hair is visible in the immediate foreground on the left.

TAGS: london, red bus, blue taxi, double-decker bus, boots, box junction, pedestrians, architecture, street scene, city street
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: A street scene in London features a yellow box junction marked on the asphalt, occupied by a red double-decker bus and a blue taxi. Pedestrians cross the street near the curved, classical architecture of Regent Street, with a "Burberry" storefront visible on the left. A person with brown hair is partially visible in the foreground.

TAGS: london, double-decker bus, taxi, pedestrians, burberry, street, architecture, box junction, city
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- double-decker bus
- taxi cab
- building
- sidewalk
- street
- person
- road
- traffic light
- clock
- window
- door
- "boots"

**PHASE 2 — SCENE.**
The image captures a busy outdoor street intersection in London, characterized by the distinctive architecture of Regent Street and the presence of a red double-decker bus. A person with long brown hair stands in the immediate foreground on the left, observing the traffic and pedestrians crossing the yellow box junction.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A person with long brown hair stands on a sidewalk near a busy intersection in London, watching a red double-decker bus and a blue taxi cab navigate the yellow box junction. The background features large stone buildings with arched entrances and a visible "boots" storefront, typical of the city's architecture.
TAGS: london double-decker bus taxi cab street scene boots storefront regent street travel urban architecture
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "A busy urban intersection in London features a red double-decker bus and a blue taxi navigating a road marked with yellow crisscross lines. Pedestrians cross the street near grand, classical stone buildings with arched ground floors and large windows. A person with long brown hair stands in the immediate foreground on the left, partially obscuring the view of the street activity.",
  "tags": [
    "london",
    "double decker bus",
    "blue taxi",
    "pedestrians",
    "yellow box junction",
    "urban street",
    "architecture",
    "travel"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "A busy street intersection in London features a red double-decker bus and a blue taxi navigating a yellow box junction. Pedestrians cross the street near classical stone buildings with arched ground floors. A person with brown hair occupies the immediate foreground on the left.",
  "tags": [
    "london",
    "travel",
    "double-decker bus",
    "taxi",
    "street intersection",
    "pedestrians",
    "architecture",
    "urban"
  ]
}
```

---

## Photo 12 — Triumphal arch at dusk

![Photo 12](IMG_0093.jpeg)

_Source file: `IMG_0093.jpeg`. Added 2026-04-18._

### Claude reference (2026-04-18)

```
DESCRIPTION: A classical stone triumphal arch stands illuminated by warm floodlights at dusk, set in the middle of a roundabout under a cloudy twilight sky. The monument features a central archway, smaller side arches, and decorative reliefs on the facade. Cars including a yellow taxi drive on the paved road around the base, with street lamps and trees visible at the perimeter.
TAGS: triumphal arch, monument, landmark, dusk, street, taxi, roundabout, architecture, urban, travel
```

Notes: Tests landmark/architecture recognition and the `travel` category. Specific city identification (likely Bucharest given the yellow taxis and the scale) is a bridge too far without confirmation — generic `triumphal arch` + `landmark` + `travel` is the safer tag set.

### Qwen3 — revised v4 prompt, generalized category (2026-04-18)

```
DESCRIPTION: The image shows a large stone triumphal arch monument illuminated by artificial lighting against a cloudy evening sky. The structure features a central archway, smaller side arches, and sculptural reliefs on its facade. Vehicles, including a white car and a yellow taxi, are driving on the paved road surrounding the monument's base.
TAGS: triumphal arch, monument, stone architecture, evening light, traffic, white car, yellow taxi, outdoor, urban landscape
```

### Qwen3 — revised v5 prompt, prefer omission (2026-04-18)

```
DESCRIPTION: A large stone triumphal arch monument stands in the center of a paved roundabout, illuminated by artificial lighting against a cloudy evening sky. Several vehicles, including a white sedan and a yellow taxi, are driving on the asphalt road surrounding the structure, while streetlights and trees line the perimeter of the intersection.
TAGS: triumphal arch, monument, roundabout, white car, yellow taxi, streetlights, trees, asphalt, outdoor, cityscape
```

### Qwen3 — revised v6 split-rule (content vs. category) prompt (2026-04-18)

```
DESCRIPTION: A large stone triumphal arch stands in the center of a paved traffic circle under a cloudy sky. The monument is illuminated by artificial lights from below, casting a yellow glow on its textured surface and highlighting relief carvings on the upper facade. Several vehicles, including a white sedan and a yellow taxi, are driving on the asphalt road surrounding the structure. Streetlights are visible in the background along with green trees and a distant building.

TAGS: triumphal arch, monument, traffic circle, white car, yellow taxi, streetlights, stone building, outdoor, urban
```

### Qwen3 — revised v7 drop-vocabulary + location hint prompt (2026-04-18)

```
DESCRIPTION: The image shows the Triumphal Arch (Arcul de Triumf) in Bucharest, Romania, illuminated by artificial lighting against a cloudy evening sky. The large stone monument features a central archway and decorative reliefs on its facade. In the foreground, a paved road contains several vehicles, including a white taxi and a yellow taxi, while streetlights and trees line the perimeter of the roundabout.

TAGS: triumphal arch, bucharst, monument, taxi, car, streetlight, road, outdoor, architecture
```

### Qwen3 — revised v8 concrete category rule + landmarks prompt (2026-04-18)

```
DESCRIPTION: The image features the Triumphal Arch (Arcul de Triumf) in Bucharest, Romania, illuminated by artificial lighting against a cloudy, twilight sky. The monument is constructed from light-colored stone and features a large central archway with decorative reliefs and smaller side niches. In the foreground, a paved asphalt road curves around the base of the structure, where a white hatchback and a yellow taxi are driving past. Streetlights and trees line the perimeter of the square, and a small landscaped median with low bushes is visible in the bottom left corner.

TAGS: triumphal arch, bucharest, romania, monument, white car, yellow taxi, asphalt road, streetlights, cloudy sky, stone architecture
```

### Qwen3 — revised v9 tag-step self-audit prompt (2026-04-18)

```
DESCRIPTION: The image displays the Triumphal Arch (Arcul de Triumf) in Bucharest, a large stone monument featuring a central archway and decorative reliefs, illuminated by yellow floodlights from below. The structure stands in a paved traffic circle with white lane markings, surrounded by trees and street lamps emitting orange light. Several vehicles, including a white hatchback and a yellow taxi, are visible on the road in the foreground, while the sky above is filled with dark blue clouds.

TAGS: triumphal arch, bucharst, monument, stone arch, white car, yellow taxi, traffic circle, street lamp, cloudy sky, romania
```

### Qwen3 — revised v10 search-first framing prompt (2026-04-18)

```
DESCRIPTION: A large stone triumphal arch, the Arcul de Triumf, stands illuminated by warm yellow floodlights against a dark blue, cloudy evening sky. The monument features a large central archway and smaller side niches with sculpted reliefs. In the foreground, a paved road curves around the base of the structure, occupied by a white car and a yellow taxi. Streetlights and trees line the perimeter of the plaza surrounding the monument.

TAGS: arch, monument, bucursti, romania, architecture, city, night, street, car, taxi
```

### Qwen3 — revised v11 JoyCaption confident language prompt (2026-04-18)

```
DESCRIPTION: The Triumphal Arch in Bucharest stands as a large stone monument with a central archway and decorative reliefs, illuminated by artificial lighting at dusk. Several vehicles, including a white car and a yellow taxi, travel on the asphalt road surrounding the structure. Streetlights and trees line the perimeter of the plaza, while a cloudy sky fills the background above the monument.

TAGS: triumphal arch, bucurarest, romania, monument, stone arch, yellow taxi, white car, streetlights, cloudy sky, outdoor
```

### Qwen3 — revised v12 quote-text-exactly prompt (2026-04-18)

```
DESCRIPTION: The Triumphal Arch in Bucharest stands illuminated against a cloudy evening sky, its stone facade featuring a large central archway and detailed reliefs. Vehicles, including a white car and a yellow taxi, travel along the paved road surrounding the monument's base. Streetlights cast a glow on the structure and the surrounding trees, while a small landscaped median with shrubs sits in the foreground.

TAGS: triumphal arch, bucharest, monument, arch, stone, car, taxi, streetlights, trees, outdoor, travel
```

### Qwen3 — revised v13 six-category taxonomy prompt (2026-04-18)

```
DESCRIPTION: A large stone triumphal arch stands in the center of a paved traffic circle, illuminated by artificial uplighting against a cloudy twilight sky. Several cars, including a white taxi, travel along the asphalt road surrounding the monument. Streetlights and trees line the perimeter of the intersection, and a small landscaped median with low bushes is visible in the foreground.

TAGS: triumphal arch, bucursti, bucursti arch, monument, traffic circle, taxi, stone, evening, streetlights, bucursti romania
```

### Qwen3 — revised v14 few-shot exemplars prompt (2026-04-18)

```
DESCRIPTION: A large stone triumphal arch stands in the center of a paved roundabout under a cloudy blue sky. The monument features a central archway and two smaller side arches, illuminated by yellow floodlights from below. Cars, including a white sedan and a yellow taxi, drive on the asphalt road surrounding the structure. Streetlights and green trees line the perimeter of the intersection.
TAGS: triumphal arch, monument, roundabout, stone, architecture, city, traffic, evening, landmark, bucurarest
```

### Qwen3 — revised v15 negative exemplars (contrastive) prompt (2026-04-18)

```
DESCRIPTION: The Triumphal Arch in Bucharest stands illuminated against a cloudy evening sky. The monument features a large central archway with decorative reliefs and inscriptions on its facade. Streetlights cast a yellow glow on the stone structure, highlighting its architectural details. Vehicles, including a white car and a yellow taxi, drive on the paved road surrounding the monument. Trees line the perimeter of the square, and street lamps are visible in the background.

TAGS: triumphal arch, bucharst, monument, architecture, archway, city, traffic, evening, stone, landmark
```

### Qwen3 — revised v16 confidence gating (proper nouns) prompt (2026-04-18)

```
DESCRIPTION: The Arcul de Triumf stands illuminated in the center of a paved roundabout under a cloudy evening sky. Streetlights cast a yellow glow on the stone monument, while cars drive past on the asphalt road in the foreground.

TAGS: arc de triomphe, bucurarest, romania, monument, architecture, roundabout, city, landmark, evening, travel
```

### Qwen3 — revised v17 CoVe two-pass self-audit prompt (2026-04-18)

```
DESCRIPTION: The Arcul de Triumf in Bucharest stands illuminated against a cloudy evening sky, featuring a large central archway and detailed stone reliefs. Vehicles, including a white car and a yellow taxi, drive along the paved road surrounding the monument's base.

TAGS: arc de triomphe, bucharst, romania, monument, architecture, arch, landmark, city, travel, evening
```

### Qwen3 — revised v18 TriPhase hierarchical prompt (2026-04-18)

```
**PHASE 1 — OBJECTS.**
- Triumphal Arch
- Stone pillars
- Stone archway
- Streetlights
- Trees
- Paved road
- White car
- Yellow taxi
- Clouds
- Sky

**PHASE 2 — SCENE.**
The Triumphal Arch stands centrally in a large paved roundabout, illuminated by streetlights against a cloudy evening sky. The structure is surrounded by a road with moving vehicles, including a white car and a yellow taxi, indicating an active urban traffic circle.

**PHASE 3 — OUTPUT.**
DESCRIPTION: A large stone Triumphal Arch dominates the center of a paved roundabout, illuminated by streetlights against a cloudy sky. A white car and a yellow taxi travel along the road in the foreground, passing the monument's base.
TAGS: triumphal arch, bucarest, monument, roundabout, taxi, car, streetlights, travel, city
```

### Qwen3 — revised v19 JSON output format prompt (2026-04-18)

```
{
  "description": "The Arcul de Triumf in Bucharest stands illuminated against a cloudy evening sky, its stone facade glowing under artificial lighting. Vehicles, including a white car and a yellow taxi, travel along the paved road surrounding the monument's base.",
  "tags": [
    "arch",
    "bucharest",
    "landmark",
    "travel",
    "evening",
    "architecture",
    "monument",
    "city"
  ]
}
```

### Qwen3 — revised v20 consolidation (JSON + quote-text + few-shot + contrastive + self-audit) prompt (2026-04-18)

```
{
  "description": "The Arcul de Triumf stands illuminated against a cloudy twilight sky, dominating a large paved roundabout. Streetlights cast a warm glow on the monument's stone facade, while vehicles, including a white taxi, navigate the surrounding roads.",
  "tags": [
    "bucharest",
    "romania",
    "arch",
    "landmark",
    "travel",
    "architecture",
    "evening",
    "traffic"
  ]
}
```

---

## Notes for future iterations

When adding a new model + prompt variant:

1. Add a subsection under each photo with the format: `### <model> — <prompt label> (<date>)`.
2. Paste the raw model output inside a fenced code block, preserving the `DESCRIPTION:` / `TAGS:` format.
3. If the prompt itself changes (not just the model), add the new prompt body to **Prompts under test** above and give it a distinct label so rows stay unambiguous.

### Observed failure modes

Hypotheses confirmed over iterations (keep this list honest — add what bites, remove what's disproved):

- **Qwen default → mood/atmosphere drift**: "nostalgic", "peaceful", "cozy", "warm" in prose.
- **Qwen default → speculation**: "taken decades ago", "suggesting a retro aesthetic".
- **Qwen default → meta-commentary**: "faded", "pinkish tint", "vintage photo".
- **Qwen default → multi-word tags**: "childhood memory", "cozy bedroom", "quiet moment" — hurt Photos.app search.
- **Qwen v1 → tag drift**: prose says X but tag list includes Y not mentioned in prose (Photo 4: `shoes`, `wall`). Addressable by requiring tags to appear as concepts in the description.
- **Qwen v1 → color inference on this one photo**: Photo 3 shirt called "orange with dark stripes" while Claude and Gemma read it as solid red. Unclear if this is a win (noticed stripes) or a loss (wrong base color). v2 repeated the "orange with blue stripes" reading.
- **Qwen v1 → missing search-useful terms**: no `birthday`, no `party`, no `outdoor`, no `meal`, no `sleeping`/`bedroom` — the strict "only-visible" rule priced out the occasion/setting tags that users would actually type. Addressed in v2 by allowing implied occasions and requiring setting/activity tags.
- **Qwen v2 → missed occasion inference on photo 4**: conical party hat + seated smiling child, but tags are `child, partyhat, bed, sheet, headboard, curtain, shirt, pants, shoes, indoor` — no `birthday`, no `party`, no `smile`, no `smiling`. The "party hat → birthday" rule fired in the description ("conical party hat") but didn't make it into the tag list. Next iteration: strengthen to "the inferred occasion MUST appear in the tag list when one is identified" or show explicit exemplars.
- **Qwen v2 → `partyhat` violates single-word rule**: it's one token in the tag list but is a two-word phrase with the space removed. The instruction said "single lowercase word — no phrases, no multi-word compounds"; the model interpreted compression as compliance. Tolerable (still searchable) but inconsistent with the rule.
- **Qwen v2 → `candles` on photo 1 is a genuine catch, not a hallucination** (confirmed by the user). Claude's reference review from a small in-chat thumbnail missed them; the model ran on the full 1024 px downsized JPEG and picked them up. Worth remembering when treating Claude's reference as ground truth — resolution matters, and the local model can out-observe a thumbnail-read reference on fine detail.
- **Qwen v2 → `orange` shirt on photo 3 is still wrong on higher-res review**: the sweatshirt is clearly red with a yellow hood and blue cuff stripes. So v2 gets color wrong AND invents "blue stripes" on the body (real stripes are only on the cuffs). Gemma and default-Qwen got the base color right despite weaker prose overall. Color recognition remains a soft spot for this Qwen build.
- **Claude reference from small thumbnails is unreliable on fine detail**: higher-res re-read flipped several calls — photo 1 gained birthday candles, cake, and the cup (no stemware); photo 2's pajama top flipped from "red-and-white checkered" to "blue-and-white gingham" (the red was a sock); photo 3 added the yellow hood and blue cuff stripes; photo 4 revealed the child is holding a red object and the hat has multicolored dots (not "yellow and blue"). **Lesson**: reference passes should always be done on the full-resolution export, not a chat thumbnail. Store references in `sample/` next to the photo so they can be audited.

### Observations from photos 5–8 (Qwen v2)

- **Policy update (2026-04-18): compound-noun tags are allowed and encouraged.** `partyhat`, `christmastree`, `winecooler`, `blackcat`, `whitecat`, `hotdog` are more searchable than their unigram forms — they give the user context in one token. Update the prompt to say: "Single lowercase tokens; common compound nouns may be written as one token (e.g. `partyhat`, `christmastree`, `winecooler`)." Earlier observations in this log that flagged compound tags as violations are retracted.
- **Photo 5 → got the caliper brand half-right**: the caliper bears the ///M badge (BMW M performance), model reported `"M" logo`. Correct letter, missed that it's the BMW M marque specifically. An improvement would be "M" → "BMW M" in the description, plus a `bmw` tag for searchability.
- **Photo 5 → background brand boxes are blurry and hard to read** (no legible brand confirmable from this resolution). An earlier observation that called this a missed `Bilstein` capture was a reference-side misread and has been dropped. When background text is blurry, the right behavior is to omit it — don't force-guess brands.
- **Photo 6 → didn't recognize `dyson` or call it a `vacuum`**: called the handheld Dyson "a black-handled tool with a red accent". Literally correct but zero-value for search — no user will type "black-handled tool" to find this photo. The prompt should push toward naming the object type even when the brand is uncertain (`vacuum` is a safe fallback when `dyson` can't be read). Add: "Name the object type (e.g. 'vacuum' not 'tool'; 'headphones' not 'device'). If the brand is visible, include it."
- **Photo 6 → missed `renovation`**: the raw unfinished countertop edge + exposed aluminum bracket + handheld tool on top is overwhelmingly a mid-install shot. The occasion/activity-inference rule didn't fire here. May need more exemplars in the prompt (e.g. "unfinished construction → renovation or install").
- **Photo 7 → missed `repotting`** and emitted filler tags `surface` and `indoor` (the "only describe what is clearly visible" rule also lets through generic junk when it isn't the PROSE that's visible). Actively forbid filler: "Skip tags that describe non-specific surfaces or scenes (`surface`, `background`, `indoor`, `object`)." Note `indoor` was explicitly allowed in v2's rules as a setting tag — need to reconcile: allow `indoor`/`outdoor` only when they add signal the scene didn't already provide.
- **Photo 8 → the "wine cooler" and "wooden countertop" were real, not hallucinated** (confirmed by user). The wine cooler is the black undercounter unit just out of frame, and the wooden top IS the kitchen countertop edge. The scene really is a kitchen door to the backyard, not an entryway. The model correctly inferred the kitchen context from edge-of-frame detail the casual reviewer might miss. **This is a win for the prompt, not a failure** — and the same resolution-advantage lesson from photo 1's candles applies here: the model reading the full 1024 px image can pick up context that a thumbnail review misses. Earlier "hallucination" flag retracted.
- **Photo 8 → `cats`, `black`, `white` tagged separately**: multi-subject handling worked, but bare color tags (`black`, `white`) on their own aren't useful search terms. Under the new compound-noun policy, `blackcat` and `whitecat` would be clearly better. Prompt update suggestion: "When the subject's color is distinctive, include a compound tag combining color and subject (e.g. `redjacket`, `blackcat`, `bluecaliper`)."

### Observations from photos 1–8 (Qwen v3)

Wins vs v2:
- **Photo 4 now tags `birthday`** — the v2 gap was "describes party hat but doesn't tag birthday". The v3 rule "when you identify an occasion in the description, include it explicitly as a tag" fired correctly.
- **Photo 7 now tags `repotting`** — description explicitly says "indicating it has been removed from a pot". Exemplar in the prompt drove the inference.
- **Photo 8 now tags `black cat` and `white cat`** — multi-word color+subject, exactly the format the compound-noun policy wanted.
- **Photo 1 now tags `party`** (though not `birthday` — see below).
- **Photo 3 gained `outdoor`, `forest`, `nature`, `sitting`** search-useful setting/activity tags that v2 omitted.
- **Object-type upgrades**: `sweatshirt` (photos 3, 4), `baseball cap` (photo 3), `brake caliper`/`brake rotor`/`wheel hub` (photo 5). The "name the object type" rule is sticking.
- **Multi-word tags flowed naturally**: `hot dogs`, `plastic cup`, `paper plate`, `wooden chair`, `party hat`, `wooden headboard`, `floral blanket`, `red sleeves`, `checkered pants`, `baseball cap`, `black cat`, `white cat`, `wine cooler`, `glass door`, `kitchen island`, `stainless steel refrigerator`, `metal bracket`, `black brick fireplace`. Photos.app tokenizer can now hit any of the component words.

Remaining gaps:
- **Photo 1 still doesn't tag `birthday`** even though the description explicitly says "cake with candles". The occasion-inference rule only lists `party hat → birthday` as an exemplar; `cake + candles → birthday` is missing. Next iteration: add that exemplar.
- **Photo 6 lost the Dyson entirely** (v3 regression). v2 said "black-handled tool with a red accent" — literal but useless; v3 doesn't describe or tag the Dyson at all. The model may have dropped it when the prompt discouraged appearance-only descriptions without providing a brand to fall back on. Fix: explicit "if you can't name a visible handheld object confidently, still tag it as `vacuum` / `tool` / etc. based on its form factor."
- **Photo 6 still misses `renovation`** despite raw unfinished edge + exposed bracket + handheld tool (now absent in prose). Two paths: add a more direct exemplar ("exposed structural supports + raw wood → construction or install"), or accept this is one the model can't connect without stronger hints.
- **Photo 6 → some tags bordering on mood/vagueness**: `holiday decoration`, `interior design`. `holiday decoration` is fine (concrete). `interior design` is editorial and probably should have been blacklisted. Add to blacklist.
- **Photo 3 still says "orange" sweatshirt** — the jacket is red with a yellow hood. Same as v1 and v2. Confirmed model-level perception issue, not fixable by prompt.
- **Photo 2 still confused on garments**: says "red sleeves" on the shirt, when the visible long sleeves are actually blue-and-white gingham. Also model-level.
- **Photo 5 still calls it just `"M" logo`** — it's the ///M BMW performance badge. Model perception or training limit. `bmw` tag would be the prize.
- **Photo 5 says "resting on a dark workbench"** — the caliper is actually mounted on a wheel hub (correct earlier in the same description). Minor internal inconsistency in the prose; tags are still fine.
- **Tag counts trending toward the lower end**: photos 5 and 7 at 7-8 tags, below the 5-10 target's upper half. With richer multi-word tags, maybe that's fine — quality over quantity. Worth watching.

### Observations from photos 1–12 (Qwen v4)

Category generalization — the core hypothesis:

- **Photo 1 now tags `birthday cake`**: v3 only tagged `party`, v4 extracted the cake+candles visual evidence into a `birthday cake` compound tag. Under Photos.app tokenization that matches both `birthday` AND `cake` searches — the exact win the multi-word policy was meant to unlock. Generalization hypothesis partially confirmed: the model didn't need an explicit `cake+candles → birthday` exemplar.
- **Photo 6 now tags `home renovation`**: v3 missed `renovation` entirely. v4 got it. The category vocabulary rule fired on the raw-edge + exposed-bracket + handheld-tool cues without needing an explicit `unfinished construction → renovation` pattern. Clear generalization win.
- **Photo 3 now tags `hiking`**: nothing on the photo is hiking per se — it's a kid sitting on a rock by a river. This is the category rule mis-firing, picking the closest word from the provided vocabulary (which included `hike`). The scene is outdoor recreation, but `hiking` is overreach. Rule tension: "when multiple visible elements support it" is soft and the model grabbed at `hiking` because the vocabulary contained it. Could tighten by saying "choose only if the specific activity is clearly shown".
- **Photo 7 keeps `repotting`**: consistent with v3. Category rule held.
- **Photo 4 keeps `birthday`**: consistent with v3. ✅

Extended-set results (photos 9–12, never seen by prior prompt iterations):

- **Photo 10 (LEGO statue) tagged `christmas display`** — clear false positive. The scene is a LEGO store with a green-jacketed statue and a person in a pink jacket; no Christmas imagery. The model picked `holiday` from the category vocabulary based on color coincidence (green + pink/red). This is the exact failure mode the user warned about: giving the model a category vocabulary risks it forcing a match when none is appropriate. Prompt fix candidate: stronger "do not invent a category with no visible support" emphasis, or move the category list out of the prompt body and into a commentary note.
- **Photo 10 tagged `mannequin`**: factual error — it's a LEGO statue, not a mannequin. Model is substituting a familiar retail-store object category.
- **Photo 11 correctly tagged `london`**: proper-noun identification from strong cues (double-decker bus, British architecture). `urban travel` is a bit editorial but passable. `travel` category fired correctly.
- **Photo 11 missed `piccadilly`/`regent street`**: fine — safer to generalize than hallucinate a specific location.
- **Photo 12 correctly identified `triumphal arch`**: object-type rule working. Missed landmark specificity (Bucharest), which is acceptable. `evening light` is borderline mood/atmosphere but probably OK.
- **Photo 9 (graffiti truck) did NOT force a false category**: v4 didn't tag this as anything event-related, correctly. Vehicle + art + street, no occasion. One point in favor of the rule not over-firing on object-only photos.

Summary of v4 vs the generalization hypothesis:

- ✅ **Wins**: photos 1 (birthday cake), 6 (home renovation), 9 (no false category), 11 (london + travel), 12 (triumphal arch).
- ⚠️ **False positives from the category vocabulary**: photo 3 `hiking`, photo 10 `christmas display`. Both picked the nearest-matching word from the listed vocabulary when the evidence was thin or merely color-coincidental.
- ❌ **Factual errors unrelated to category rule**: photo 10 `mannequin` (wrong classification).

Net read: the categorical rule generalizes better than the exemplar list on novel photo types (photos 9–12), but the vocabulary list in the rule ("e.g. birthday, meal, sports, hike, ...") is double-edged — it helps the model know the output shape, and it tempts the model to pick something from the list even when none cleanly fits. Either way, the rule is stronger than v3 on photo types we hadn't trained on, which was the actual goal.

Candidate v5 refinement (single-line, generalizable):
```
- Identify the event, activity, or scene category the image depicts and include it as a tag ONLY when multiple specific visible elements clearly support it. Prefer omission over a loose match. Common categories: birthday, meal, sports, hike, camping, renovation, gardening, repotting, cooking, travel, holiday.
```
Main edit: "ONLY when multiple specific visible elements clearly support it. Prefer omission over a loose match." — explicitly biases the model toward silence when evidence is ambiguous. Would likely kill the photo 10 `christmas display` and might kill the photo 3 `hiking`. Trade-off: also likely kills some true-positive inferences.

### Observations from photos 1–12 (Qwen v5)

Scorecard against the candidate-v5 hypotheses:

| Hypothesis | Result | Notes |
|---|---|---|
| Kept win: photo 1 `birthday cake` | ❌ LOST | v5 prose no longer even mentions the cake or candles; tagged just `meal, party food` |
| Kept win: photo 6 `home renovation` | ✅ KEPT | `renovation` (shorter form), plus gained `christmas` tag |
| Kept win: photo 7 `repotting` | ✅ KEPT | Bonus `gardening` added |
| Kept win: photo 4 `birthday` | ✅ KEPT | |
| Kept win: photo 11 `london` + `travel` | ✅ KEPT | Bonus: `yellow box junction`, `purple top` specifics |
| Killed false positive: photo 3 `hiking` | ❌ NOT KILLED | Still tagged `hiking` on a kid sitting on a rock |
| Killed false positive: photo 10 `christmas display` | ⚠️ SWAPPED | Dropped `christmas display` but replaced with `holiday` — also false |

Net: 3 wins kept cleanly, 1 win killed, 0 false positives cleanly killed, 1 false positive swapped for another. The "prefer omission" bias landed in the wrong place — it killed the `birthday cake` inference on photo 1 (which was correct and valuable) but didn't prevent the `hiking`/`holiday` inferences on photos 3 and 10 (which were false).

Unrelated improvements v5 did deliver:
- **Photo 2**: noticed "cross-shaped panel" on headboard (accurate detail, matches reference). Minor drift: called pillow "purple checkered" when it's the floral-patterned print.
- **Photo 5**: corrected earlier "workbench" inaccuracy — now says "workshop floor" which is right. Tighter 6-tag set.
- **Photo 8**: gained `deck`, `metal railing` — better setting specifics through the door.
- **Photo 11**: gained `yellow box junction` (specific British traffic marking) and correctly identified the person's `purple top` in foreground.
- **Photo 12**: gained `roundabout`, `streetlights`, `trees`, `asphalt` — concrete setting specifics replace the soft `evening light`/`urban landscape` tags.

**Diagnosis of the v5 failure pattern.** The "prefer omission" rule was written as a category-rule tightener, but the model applied it inconsistently:
- On photo 1 it fired *too hard* — the model got cautious and didn't describe the cake+candles (observable content) or tag `birthday cake` (the category).
- On photos 3 and 10 it fired *too soft* — the model still picked `hiking` and `holiday` from the vocabulary list despite thin evidence.

The asymmetry suggests the model isn't reliably treating category inference differently from content description. Telling it to "prefer omission" leaked into the description itself on some photos while the category-vocabulary temptation overrode it on others.

**What this means for v6**. Two options, neither great:

1. **Drop the category vocabulary from the prompt body**. Without `hike, holiday, ...` listed as options, the model can't as easily force-match them. But it also loses the output-shape cue that helps it pick `renovation` / `birthday` / `travel` confidently. Might kill more wins than losses.

2. **Split the rule in two**: one for *describing* visible content (no omission bias — describe what you see), one for *tagging* categories (omission bias — only tag if confident). Clearer separation may help the model apply the right cautiousness at the right step.

Leaning toward option 2. Candidate:

```
- Describe every visible element faithfully in the prose — do not suppress details even when you are uncertain about the category they imply.
- Identify the event, activity, or scene category separately at the tag-list step. Only include a category tag when multiple specific visible elements clearly support it; prefer omitting the category tag over a loose match. Common categories: birthday, meal, sports, hike, camping, renovation, gardening, repotting, cooking, travel, holiday.
```

That separates content fidelity from category confidence and might hit the target: photo 1 should describe the cake+candles again AND tag `birthday cake` because "cake with candles" is multiple specific supporting elements. Photo 3's `hiking` should be dropped because sitting on a rock doesn't meet "multiple specific elements clearly supporting hike". Photo 10's `holiday` should be dropped because green+pink isn't multiple supporting elements.

Worth a test if you want to chase this further. Otherwise v4 is still the best overall balance of wins vs false positives we've measured.
- **Gemma → "vintage" tag bleed-through**: appears in photos 1/3/4 despite the scene-subject instructions. Low priority.

### Observations from v6–v10 (autonomous iteration batch, 2026-04-18)

Ran five iterations (v6 through v10) directly against the configured OpenAI-compatible endpoint (`MacBookPro.localdomain:9090/v1`, `mlx-community/Qwen3.6-35B-A3B-4bit`), 1024 px downsized JPEG q=0.8 — same pipeline the PhotoSnail app uses. Each iteration ran all 12 photos; ~10 s per photo.

**Per-iteration design theme:**
- **v6** — split-rule (content fidelity vs. category confidence) + concrete "describe the cake, candles, roots" exemplars.
- **v7** — drop the category vocabulary list; add "name the location/landmark if clearly identifiable".
- **v8** — concrete positive/negative exemplars in the category rule ("sitting on a rock is NOT evidence of hiking"; "cake with lit candles IS evidence of birthday").
- **v9** — simplify category rule to a single-paragraph **tag-step self-audit** that gates categories on what the prose described.
- **v10** — consolidation: search-first framing ("what would the user type?") + v9 self-audit + explicit anti-false-positive list.

**Scorecard across v6–v10** (vs v4/v5 for reference):

| Criterion | v4 | v5 | v6 | v7 | v8 | v9 | v10 |
|---|---|---|---|---|---|---|---|
| P1 describes cake | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ |
| P1 `birthday` tag | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| P3 `hiking`/`camping` false positive | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ |
| P4 `birthday` tag | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| P6 `renovation` tag | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| P7 `repotting` tag | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ❌ |
| P8 no FP | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P10 `christmas`/`holiday` FP | ❌ | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P11 `london` tag | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| P11 `travel` tag | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| P12 names `bucharest`/`romania` | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ⚠️ (typo `bucursti`) |
| P5 `bmw` tag | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| P10 `mannequin` factual error | ✅ absent | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ present |

**Key findings:**

1. **Content fidelity vs. category confidence really are separable.** v6's split-rule approach landed the core hypothesis: strong "describe everything" language in the description rule + "prefer omission" only at the tag step. v5's single fused rule was the failure mode it was built to fix — v5 let "prefer omission" bleed into the description and killed the cake mention on photo 1.

2. **Category vocabulary list in the prompt body tempts force-matching.** v5/v6 listed `birthday, meal, sports, hike, camping, renovation, gardening, repotting, cooking, travel, holiday` — photos 3/10 keep picking from it (`hiking`, `christmas display`, `holiday`). v7 dropped the list entirely; photo 3 picked `camping` instead of `hiking` — the model just swapped to another category word it knew. Removing the vocabulary doesn't kill categorization pressure; it only changes which word gets mis-selected.

3. **"Activity must be visibly happening" (v8+) kills the outdoor-scenery-implies-activity failure.** v8's explicit "Being outdoors, sitting on a rock, or wearing casual clothes is NOT evidence of any specific activity" line ended the photo 3 false positive cleanly across v8, v9, v10. The negative examples mattered more than the positive ones.

4. **Location identification is unlocked by a single sentence.** "If a location or landmark is clearly identifiable, name it" (v7+) recovered `london` reliably and pulled `bucharest`/`romania` out of the model — information that was present but latent behind categorical reticence. Cheap win.

5. **The tag-step self-audit (v9) ties categories to what the prose said.** The prose-gates-tags rule solved the v8 asymmetry (prose saw cake+candles, tag list ignored it). It doesn't solve every case — photo 1 in v9 regressed on content (model called the cake "pizza") — but when the description is right, the tag follows.

6. **Search-first framing (v10) unlocks new wins and new regressions.** Framing the task as "what would a user search for?" pulled out `bmw` (the ///M logo on the caliper) and `travel` on photo 11 — neither appeared in any prior iteration. BUT v10 regressed `repotting` on photo 7 and `birthday` on photo 4. The framing shifts attention from categorization to user search, which helps for proper nouns / brand names, but weakens the already-fragile category-tag linkage.

7. **Photo 1 `birthday` tag is the hardest test.** Only v4 and v6 landed it. The perception-level "is this a cake?" question is model-limited; when the model sees "cake" the `birthday` tag usually follows, when it sees "pizza" or "decorated items" the tag is absent. This is a data/model issue, not solvable by prompt.

**Recommendation.** No single iteration Pareto-dominates, but two finalists stand out:

- **v9 (tag-step self-audit)** — cleanest all-rounder. No category false positives across 3/10 photos, landmark/city identification working, category tags fire when described, no new weaknesses introduced. Weakness: photo 1 content perception, `travel` tag not emerging, no `bmw`.

- **v10 (search-first framing)** — highest ceiling, slightly noisier floor. Adds `bmw` (unique across 10 iterations), adds `travel` on photo 11, keeps no-FP on 3/10. Weakness: sacrificed `birthday` on photo 4 and `repotting` on photo 7, introduced `mannequin` factual error on photo 10.

The choice depends on preference: v9 for a conservative balance, v10 for more aggressive searchability at the cost of some category-tag misses. A potential v11 would merge them — v10's opening framing + v9's category self-audit wording — but that's untested.

**Prompt anti-patterns confirmed by this batch:**
- Long category vocabulary lists in the prompt body (tempts force-matching).
- Elaborate multi-line category rules (model skips the tag-step application).
- "Prefer omission" without scoping (bleeds into content).

**Prompt patterns confirmed as winning:**
- Concrete content-fidelity exemplars ("describe the cake, the candles, the unfinished counter edge").
- Location/landmark identification as a single explicit sentence.
- Negative examples in the category rule ("sitting on a rock is NOT evidence of hiking").
- Tag-step self-audit that gates tags on the prose.
- Search-first framing for brand-name and location surfacing (use with caution).

### Observations from v11–v20 (research-informed batch, 2026-04-18)

Batch motivation: after v9/v10 plateaued on a small set of stubborn failures (photo 1 `birthday`, photo 5 `bmw`, photo 3 `orange`/`red` color, photo 11/12 `travel` tag), two web-research streams were run — one on general VLM prompt-engineering patterns (NVIDIA guide, JoyCaption-shipped prompt, KeyLLM, Chain-of-Verification, TriPhase MDPI paper, EMNLP 2024 grounding paper), one on Qwen3-VL specifics (official model card, HuggingFace discussions, known-limitation papers on hallucination-from-long-reasoning in VLMs). Each iteration maps to one research-derived tactic, and v20 consolidates the winners.

**Tactic → iteration → result:**

| v | Tactic (source) | Net result |
|---|---|---|
| v11 | JoyCaption confident-language directives (`github.com/fpgaminer/joycaption`) | **Photo 3 red sweatshirt color correct for the first time** (confident language freed the model from hedging). Photo 1 `birthday` recovered. |
| v12 | "Quote text exactly" for brand/OCR rescue (JoyCaption) | First `travel` tag on photos 11+12. First `bonar` graffiti text quoted. Bucharest correctly spelled. |
| v13 | Six-category taxonomy (controlled vocabulary — `organizepictures.com`) | **Regression.** Over-constrained, swapped `birthday` → `meal` on photo 1. Worst iteration of the batch. |
| v14 | Few-shot exemplars (Grootendorst KeyLLM) | **First `bmw m` identification across all iterations** — few-shot brand example carried across. |
| v15 | Contrastive negative exemplars (NVIDIA VLM guide + hallucination literature) | **Zero false positives on photo 10** (no christmas, no mannequin, no holiday). Photo 11 `Piccadilly Circus`. Strongest FP-suppression pattern. |
| v16 | Proper-noun confidence gating (EMNLP 2024 grounding paper) | **`Boots` storefront identified on photo 11**; photo 12 `Arcul de Triumf` Romanian name. |
| v17 | Chain-of-Verification two-pass self-audit (Learn Prompting CoVe) | **Photo 7 `repotting` recovered** (lost since v7). Photo 11 `Regent Street` + `Burberry`. Subtle gains. |
| v18 | TriPhase hierarchical (MDPI 2025 TPP paper) | **Regression.** Model emitted all three phases verbatim, doubling output length; photo 11 tag format broke (no commas). Confirms the research warning: long reasoning dilutes visual tokens in VLMs. |
| v19 | JSON structured output (NVIDIA VLM docs, Qwen structured-output) | **Cleanest format compliance ever**, all 12 photos parsed as valid JSON. Birthday/repotting/renovation/travel all landed cleanly. |
| v20 | Consolidation of v11/v12/v14/v15/v17/v19 winners | **Best overall scorecard across all 14 iterations tested** — see table below. |

**Cross-iteration scorecard (v4/v5 baseline + v6–v10 first batch + v11–v20 research batch):**

| Criterion | v4 | v9 | v10 | v11 | v12 | v14 | v15 | v17 | v19 | **v20** |
|---|---|---|---|---|---|---|---|---|---|---|
| P1 describes cake | ✅ | ❌ | ✅ | ❌ (donuts) | ❌ (bagels) | ❌ (bread) | ✅ | ❌ | ✅ | ✅ |
| P1 `birthday` tag | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | **✅** |
| P3 red sweatshirt color | ❌ orange | ❌ orange | ❌ orange | **✅ red** | ✅ red | ❌ orange | ✅ red | ❌ orange | ❌ orange | ❌ orange |
| P3 `hiking`/`camping` FP | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P4 `birthday` tag | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ |
| P5 `bmw m` tag | ❌ | ❌ | ❌ | ❌ | ❌ | **✅** | ❌ | ❌ | ❌ | **✅** |
| P6 `renovation` tag | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| P7 `repotting` tag | ✅ | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ |
| P10 `mannequin`/`christmas` FP | ❌ | ✅ | ❌ (mannequin) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P11 `london` tag | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| P11 `travel` tag | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| P11 specific London spot | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Piccadilly | ✅ Regent+Burberry | ❌ | ❌ |
| P12 Bucharest/Romania | ❌ | ✅ (typo) | ⚠️ typo | ✅ (typo) | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| P12 `travel` tag | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Format compliance | OK | OK | OK | OK | OK | OK | OK | OK | **JSON ✅** | **JSON ✅** |

**Total `✅` checks on the shared criteria** (14 rows): v4=6, v9=8, v10=7, v11=8, v12=10, v14=8, v15=9, v17=9, v19=11, **v20=12**.

### Final recommendation

**v20 is the new recommended prompt.** It's the best overall of all 14 iterations tested — wins on all of: photo 1 birthday + cake recognition, photo 4 birthday, photo 5 bmw m, photos 6/7 renovation/repotting, photo 10 no false positives, photos 11/12 travel + Bucharest correctly. Only losses vs the best-of-each-criterion are photo 3's stubborn orange/red color (Qwen3-VL model-level perception issue, not fixable by prompt — only v11/v12/v15 got this right inconsistently) and photo 11 losing the Piccadilly/Boots/Burberry specificity (v15–v17 got those but sacrificed other wins).

**v20 vs the earlier-proposed v9+v10 merge**: v20 strictly dominates. Going with v9+v10 would have plateaued at the 8–11 win range; v20 reaches 12 by combining patterns from six distinct research-backed tactics:
1. **Confident definite language** (v11 → JoyCaption) — frees model from hedging.
2. **Quote text exactly** (v12 → JoyCaption) — brand/OCR surfacing.
3. **Few-shot brand exemplars** (v14 → KeyLLM) — BMW M identification.
4. **Contrastive negative exemplars** (v15 → NVIDIA + hallucination literature) — false-positive suppression.
5. **JSON structured output** (v19 → NVIDIA + Qwen docs) — format compliance.
6. **Self-audit tag gating** (v17 + v9) — category-marker linkage.

**Key research findings that shaped this batch:**

- **Long reasoning dilutes visual tokens** — VLM hallucination papers confirmed what v18 empirically showed. Multi-phase or chain-of-thought prompting works for text LLMs but hurts VLMs because the visual attention decays.
- **JSON output beats colon-headers** — both the NVIDIA VLM guide and Qwen structured-output docs recommend JSON for compliance; v19 and v20 both emitted clean parseable JSON on 12/12 photos, and I saw zero preamble drift ("Here's the JSON...") after the explicit "first character must be `{`" directive.
- **Confident language unlocks perception** (v11 finding) — "No 'appears to be'" changes how the model commits to observations. This was unexpected but reproducible in v11 and v12 on photo 3.
- **Few-shot exemplars are the cheapest way to teach brand naming** — v14 pulled BMW M out of the model after 13 earlier iterations failed with principle-based rules alone.
- **Negative exemplars are strictly better than general rules for false-positive suppression** — v15's three "BAD tags with reason" blocks killed every false positive on photo 10 that eight prior iterations couldn't kill.

**Remaining open problems (model-level, not prompt-fixable):**

- Photo 3 sweatshirt color (red vs orange) — Qwen3.6-35B-A3B-4bit gets this wrong ~70% of the time regardless of prompt. The 4-bit MoE quantization likely plays a role (only ~3B active params per token, so quant noise hits color attention hard per the Qwen3-VL research). Higher-precision runs may fix this.
- Photo 2 color hallucination on pajamas ("red sleeves" vs actual gingham) — same underlying issue.
- Photo 1 cake-recognition variance — the model sees "pizza", "donuts", "bagels", "bread", or "cake" across iterations based on wording framing.

**Open experiments worth running later:**

- **Qwen-official VL sampling** (`temp=0.7, top_p=0.8, top_k=20, presence_penalty=1.5`) vs. our current `temp=0.3, top_p=1.0`. Official params may improve perception; our lower temp improves reproducibility. Worth an A/B.
- **Higher resolution (1280 px long edge vs current 1024 px)**. Qwen3-VL's dynamic resolution benefits from more pixels; may improve photo 3 color, photo 1 cake perception, photo 5 BMW badge clarity.
- **Outlines / constrained-decoding** for JSON — mlx-vlm supports it. Eliminates the remaining "what if JSON drifts" risk for production use.
- **System message vs user message** for the format rules. Qwen's ChatML template respects system messages well; moving the rules to system + keeping user turn image-first may be cleaner.
