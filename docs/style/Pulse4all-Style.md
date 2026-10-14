# Pulse4all Style Guide

> Standalone brand and UI style reference for Pulse4all B.V. (P4A)
> Based on: Visual Identity Book v1.1 (February 2026, Tymen Design Work) and the August 2026 company deck template
> Document version: 2026-10-03 · Language: English (UI copy examples in Dutch)

Use this file as project knowledge or as a `STYLE.md` in a repo. It covers brand foundations, colour and type tokens, writing rules, UI component specs, document and deck conventions, photography direction and a pre-delivery checklist. Everything agent-facing or customer-facing that carries the Pulse4all brand should follow it.

**Scope note for internal tooling:** the Invest Agent UI is deliberately kept Steam-Connect-styled (parity with the current screen, Dutch copy). The Subs/Newco Agent UI, the Callcenter-Management-App (CMA), web forms and all external material use this guide.

---

## 1. Brand foundations

**What Pulse4all is:** an all-inclusive AED subscription service that makes cardiac protection simple, affordable and accessible for consumers and SMBs. A second business line (Invest) raises capital through a European bond proposition under AFM supervision.

**Vision:** by 2040, no life is lost unnecessarily to sudden cardiac arrest

**Brand promise:** hassle-free, reliable, simple

**Core values**

| Value | Meaning |
|---|---|
| Betrouwbaar | Always ready, always working |
| Gemakkelijk | The subscription removes all complexity |
| Baanbrekend | An innovative model removes barriers |
| Toegankelijk | Cardiac safety for everyone, not only organisations |

**Three test questions for every design choice**

1. Is it human — does it centre people, warmth and connection
2. Does it serve the mission — does it contribute to saving lives
3. Does it simplify — does it reduce complexity and create clarity

**Design feel in three words:** calm, light, spacious

---

## 2. Colour system

### 2.1 Palette

| Name | Hex | RGB | Role |
|---|---|---|---|
| Sand | `#FFFDF6` | 255 253 246 | Primary background |
| Warm Off-White | `#FDFBF1` | 253 251 241 | Alternative light background |
| Pure White | `#FFFFFF` | 255 255 255 | Clean backgrounds, text on dark |
| Background Blue | `#EAF4FC` | 234 244 252 | Secondary background, cards, feature circles |
| Feature Blue (on dark) | `#E3EEFD` | 227 238 253 | Feature circles on Deep Blue surfaces |
| Light Blue | `#9ECFF5` | 158 207 245 | Accents, highlights, chart secondary |
| Denim Blue | `#3B6FB3` | 59 111 179 | Secondary blue elements, hover states |
| Deep Blue | `#265BA4` | 38 91 164 | Primary brand, buttons, deck titles, links |
| Deep Blue Heading | `#2E61A6` | 46 97 166 | Heading text in documents and web |
| Leaf Green | `#27AE6F` | 39 174 111 | CTA, positive and success signals |
| Soft Rose | `#F4D9D0` | 244 217 208 | Warm accent — never alone |
| Inkt | `#0B133D` | 11 19 61 | Dark backgrounds, maximum contrast |
| Inkt Body | `#1C2127` | 28 33 39 | Body text on light backgrounds |
| Deck Body | `#0B143E` | 11 20 62 | Slide body text (deck template only) |
| Footnote Grey | `#666666` | 102 102 102 | Footnotes, sources, captions |

### 2.2 Usage rules

- Light tones dominate — Sand, white and Background Blue carry most surfaces
- Headings are always Deep Blue `#2E61A6`, body text is Inkt `#1C2127`
- Soft Rose is never used alone; always pair it with Deep Blue or Inkt
- Leaf Green is reserved for calls-to-action and affirmative signals, not for decoration
- Deep Blue `#265BA4` is the fill for primary buttons and full-bleed section slides
- Grey `#666666` only for footnotes, sources and metadata

### 2.3 Semantic colours for software (proposed defaults)

The brand book defines no error or warning colours. These derived defaults keep contrast and tone consistent; treat them as the project standard until the brand owner (Mark) says otherwise.

| Semantic | Hex | Use |
|---|---|---|
| Success | `#27AE6F` | Confirmations, saved states, positive counters |
| Success surface | `#E6F6EE` | Light background behind a success message |
| Warning | `#C98A1B` | Needs attention, non-blocking |
| Warning surface | `#FBF1DC` | Light background behind a warning |
| Error | `#B8433C` | Validation errors, failed actions |
| Error surface | `#F8E4E1` | Light background behind an error (Soft Rose family) |
| Info | `#265BA4` | Neutral informational notices |
| Info surface | `#EAF4FC` | Background Blue |
| Border | `#D9E2EC` | Dividers, input borders on light |
| Muted text | `#5B6472` | Placeholders, secondary labels |

Keep messaging calm even in error states: say what happened and what to do next, no alarm colours at full saturation on large areas.

### 2.4 CSS custom properties

```css
:root {
  /* brand */
  --p4a-sand: #FFFDF6;
  --p4a-offwhite: #FDFBF1;
  --p4a-white: #FFFFFF;
  --p4a-bg-blue: #EAF4FC;
  --p4a-bg-blue-dark: #E3EEFD;
  --p4a-light-blue: #9ECFF5;
  --p4a-denim: #3B6FB3;
  --p4a-deep-blue: #265BA4;
  --p4a-heading: #2E61A6;
  --p4a-green: #27AE6F;
  --p4a-rose: #F4D9D0;
  --p4a-inkt: #0B133D;
  --p4a-body: #1C2127;
  --p4a-grey: #666666;

  /* semantic (proposed) */
  --p4a-success: #27AE6F;
  --p4a-success-surface: #E6F6EE;
  --p4a-warning: #C98A1B;
  --p4a-warning-surface: #FBF1DC;
  --p4a-error: #B8433C;
  --p4a-error-surface: #F8E4E1;
  --p4a-border: #D9E2EC;
  --p4a-muted: #5B6472;

  /* type */
  --p4a-font: "Montserrat", "Segoe UI", Arial, sans-serif;
  --p4a-leading: 1.6;

  /* shape */
  --p4a-radius-button: 4px;
  --p4a-radius-card: 15px;
  --p4a-radius-input: 4px;
}
```

### 2.5 Tailwind extension

```ts
// tailwind.config.ts (excerpt)
export default {
  theme: {
    extend: {
      colors: {
        p4a: {
          sand: "#FFFDF6",
          offwhite: "#FDFBF1",
          bgblue: "#EAF4FC",
          bgblueDark: "#E3EEFD",
          lightblue: "#9ECFF5",
          denim: "#3B6FB3",
          deepblue: "#265BA4",
          heading: "#2E61A6",
          green: "#27AE6F",
          rose: "#F4D9D0",
          inkt: "#0B133D",
          body: "#1C2127",
          grey: "#666666",
          success: "#27AE6F",
          warning: "#C98A1B",
          error: "#B8433C",
          border: "#D9E2EC",
          muted: "#5B6472",
        },
      },
      fontFamily: {
        sans: ["Montserrat", "Segoe UI", "Arial", "sans-serif"],
      },
      lineHeight: { brand: "1.6" },
      borderRadius: { button: "4px", card: "15px" },
      spacing: { 18: "4.5rem" },
    },
  },
};
```

---

## 3. Typography

### 3.1 Typeface

**Montserrat** — geometric sans-serif, Google Fonts. It is the only typeface. Load as a variable font or the weights Light 300, Regular 400, Semi Bold 600, Bold 700 plus Italic.

```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Montserrat:ital,wght@0,300;0,400;0,500;0,600;0,700;1,400&display=swap" rel="stylesheet">
```

Fallback stack: `"Montserrat", "Segoe UI", Arial, sans-serif`

### 3.2 Weights

| Weight | Use |
|---|---|
| Light 300 | Large display text only |
| Regular 400 | Body text, inputs, table cells |
| Medium 500 | Headings (alternative to Bold), labels |
| Semi Bold 600 | Subheadings, emphasis, button labels |
| Bold 700 | Headings, strong emphasis, deck titles |
| Italic | Emphasis inside body text |

### 3.3 Type scale (web)

Line-height is 160 % everywhere unless noted.

| Token | Size | Weight | Colour | Use |
|---|---|---|---|---|
| display | 54px | Bold | `#2E61A6` | Hero titles |
| h1 | 40px | Bold | `#2E61A6` | Page title |
| h2 | 32px | Bold | `#2E61A6` | Section title |
| h3 | 24px | Semi Bold | `#2E61A6` | Sub-section |
| h4 | 18px | Semi Bold | `#2E61A6` | Card or panel title |
| body | 16px | Regular | `#1C2127` | Default text |
| body-bold | 16px | Bold | `#1C2127` | Emphasis |
| small | 14px | Regular | `#1C2127` | Secondary text, table cells |
| caption | 12px | Regular | `#666666` | Footnotes, metadata, timestamps |

Dense operational screens (agent UI, workspaces, dashboards) may step the scale down one notch (body 14px, small 13px, caption 12px) and use line-height 1.4 inside tables and data grids. Keep 1.6 for prose.

### 3.4 Type scale (documents)

| Style | Spec |
|---|---|
| Heading 1 | Montserrat Bold, 24pt+, `#2E61A6` |
| Heading 2 | Montserrat Semi Bold, 18pt+, `#2E61A6` |
| Heading 3 | Montserrat Semi Bold, 14pt, `#2E61A6` |
| Body | Montserrat Regular, 11–12pt, `#1C2127`, line spacing 1.6 |
| Caption | Montserrat Regular, 9pt, `#666666` |

---

## 4. Text and formatting rules

These are non-negotiable across all channels, including UI copy, button labels, emails and error messages.

- No ALL-CAPS — not in headings, labels, buttons or badges
- No period after a title or heading
- No periods at the end of bullet points or list items
- No exclamation marks, ever
- Always left-aligned; centred text only when strictly necessary (for example a single short statement slide)
- Short, active, direct sentences
- Numbers: use the locale of the audience (Dutch: `€ 1.250,00`, `12 maart 2026`; English UI: `€1,250.00`, `12 March 2026`)
- Dutch copy uses "je" and "wij"; French copy uses "vous"; English copy uses "you" and "we"

---

## 5. Tone of voice

Write as an expert who is also a warm human being. Not clinical, not salesy, not alarming.

**Principles**

- Expert yet approachable
- Human, not medical
- Calm and stable — reassure, do not alarm
- Positive and sober — safety and peace of mind, not fear or urgency
- Simplify — plain words, no jargon, no system talk

**Dutch do and don't**

| Don't | Do |
|---|---|
| Hartstilstand-preventie | Een veilige omgeving |
| Men kan ondersteund worden | Wij helpen je |
| Gegarandeerde ontzorging | Eenvoudig geregeld |
| Onze purpose | Onze missie |
| Let op: fout opgetreden | Dit is nog niet gelukt. Probeer het opnieuw of neem contact op |
| Verstuur webhook / trigger scenario | Verstuur e-mail / Verstuur offerte |

**UI copy rules**

- Users never see backend mechanics — no Make, webhook, API, scenario, payload, sync or technical codes in visible copy
- Button labels name the outcome for the user: "Verstuur offerte", "Sla op", "Plan terugbelafspraak"
- Confirmations state what happened and what comes next in one line
- Errors state what did not work and the single next step; no stack traces, no error codes unless support explicitly needs them
- Empty states are reassuring, not apologetic ("Nog geen taken in de wachtrij")

**Invest line (AFM-supervised):** outbound investor communication must match the prospectus. Route all 10K/100K email copy and any return-related statement through the p4a-compliance check before it ships. Calm tone still applies; precision overrides warmth where they conflict.

---

## 6. Logo

The logo is an icon mark (heart/pulse) plus a word mark. They are always used together. The round icon mark may appear alone only as a small corner mark on slides or as a favicon/app icon.

| Variant | File | Use |
|---|---|---|
| Primary — Deep Blue | `logo-blue.png` | Default on light backgrounds |
| Colour | `logo-color.png` | Marketing on light backgrounds |
| Contrast — white | `logo-white.png` | On Deep Blue or Inkt backgrounds |
| Contrast — white small | `logo-white-small.png` | Footers, slide corners on dark |
| Secondary — Inkt | derive from blue | Very light or white backgrounds needing more contrast |

**Rules**

- Clear space around the logo: at least the height of the icon mark
- Never stretch, rotate, recolour, outline, add shadows or effects
- Never place on busy photos or low-contrast areas
- Minimum width on screen: 120px (full logo), 24px (icon mark)

Asset location (internal): `style-p4a/references/assets/logos/`, icons in `assets/icons/` (people, planet, profit), product reference `assets/product/hs1_red_case.png`, font `assets/fonts/Montserrat-VF.ttf`.

---

## 7. UI components (web and app)

### 7.1 Layout

- Base grid 8px; spacing steps 8, 16, 24, 32, 48, 64px
- Content max-width 1200px for marketing pages; operational screens may use full width
- Generous whitespace — if in doubt, add 8px
- Page background Sand `#FFFDF6` (marketing) or white `#FFFFFF` (dense operational UI); cards on Background Blue `#EAF4FC` or white with a `#D9E2EC` border
- Divider lines 1px `#D9E2EC`; a thin Deep Blue divider under a page title echoes the deck header pattern

### 7.2 Buttons

| Style | Fill | Text | Border | Use |
|---|---|---|---|---|
| Primary | `#265BA4` | white | none | Main action, one per view |
| Primary hover | `#3B6FB3` | white | none | |
| Positive | `#27AE6F` | white | none | Confirm, send, book — affirmative outcome |
| Rose | `#F4D9D0` | `#0B133D` | none | Soft secondary action, always near a blue or dark element |
| Outlined | transparent | `#265BA4` | 1px `#265BA4` | Secondary action |
| Text link | none | `#265BA4` | none | Tertiary, inline |
| Destructive | transparent | `#B8433C` | 1px `#B8433C` | Delete, trash, remove — never a filled red block |
| Disabled | `#EAF4FC` | `#5B6472` | none | 60 % opacity, no hover |

- Border radius 4px
- Height 48px primary, 40px secondary and in-table actions, 32px compact (dense grids only)
- Horizontal padding 24px (primary), 16px (secondary), 12px (compact)
- Label Montserrat Semi Bold, sentence case, no trailing period, no exclamation mark
- Focus ring 2px `#9ECFF5` outside the button, offset 2px

### 7.3 Cards and panels

- Border radius 15px, padding 24px
- Background Background Blue `#EAF4FC` on Sand, or white with `#D9E2EC` border on white pages
- Title h4 (18px Semi Bold Deep Blue), body 14–16px Inkt
- No drop shadows heavier than `0 1px 2px rgba(11,19,61,0.06)`

### 7.4 Form fields

- Height 40px, radius 4px, border 1px `#D9E2EC`, background white
- Label above the field, 14px Semi Bold `#1C2127`, 8px gap
- Placeholder `#5B6472`, never used as the only label
- Focus: border `#265BA4`, ring 2px `#9ECFF5`
- Error: border `#B8433C`, helper text 12px `#B8433C` below the field, one sentence
- Required marker: the word "verplicht" in the label or an asterisk — be consistent per project
- Read-only fields: Sand background, no border, text `#5B6472`

### 7.5 Status, badges and counters

- Badge radius 4px, padding 2px 8px, 12px Semi Bold, sentence case
- Success `#E6F6EE` surface with `#27AE6F` text; Info `#EAF4FC` with `#265BA4`; Warning `#FBF1DC` with `#C98A1B`; Error `#F8E4E1` with `#B8433C`; Neutral `#F3F4F6` with `#5B6472`
- Agent-state colours (operational UI): Available Leaf Green, On call Deep Blue, Wrap-up Light Blue, Pause Warning amber, Offline Muted grey — colour is never the only signal, always show the label

### 7.6 Tables and data grids

- Header row Background Blue `#EAF4FC`, 13px Semi Bold `#2E61A6`
- Body 14px Regular `#1C2127`, row height 40px, zebra striping with `#FDFBF1`
- Right-align numbers and amounts, left-align text, tabular figures where available
- Hover row `#EAF4FC` at 50 %

### 7.7 Charts and dashboards

- Series order: Deep Blue `#265BA4`, Leaf Green `#27AE6F`, Light Blue `#9ECFF5`, Denim `#3B6FB3`, Soft Rose `#F4D9D0`, Inkt `#0B133D`
- Gridlines `#D9E2EC`, axis labels 12px `#666666`
- No 3D, no gradients, no dark backgrounds for charts on light pages
- A positive KPI delta is Leaf Green; a negative one is `#B8433C`, never a filled red tile

### 7.8 Accessibility minimums

- Body text contrast at least 4.5:1 (Inkt on Sand, Background Blue and white all pass)
- White text only on Deep Blue, Denim, Leaf Green or Inkt — never on Light Blue or Soft Rose
- Visible focus states on every interactive element
- Keyboard-first for operational screens: every primary action reachable without a mouse

---

## 8. Documents (Word, PDF, Markdown)

- Page background white or Sand `#FFFDF6`
- Margins 2.5 cm; left-aligned, ragged right
- Headings per the document type scale (section 3.4), Deep Blue, no trailing periods
- Body Montserrat Regular 11–12pt Inkt, line spacing 1.6
- Callouts: Background Blue box, 15px radius, 16–24px padding; Soft Rose only together with Deep Blue text or border
- CTA or highlighted text in Leaf Green
- Tables: Background Blue header row, 1px `#D9E2EC` borders, no heavy grids
- Footer: small logo left or right, page number and date in 9pt `#666666`
- Export to PDF with fonts embedded

---

## 9. Presentations (P4A deck template, 16:9)

Canvas 13.33 × 7.5 in, Montserrat throughout. Prefer cloning the company template (`P4A_Deck_Template.pptx`, 22 slides, August 2026) over building from scratch.

| Element | Spec |
|---|---|
| Light slide background | Sand `#FFFDF6` — never white |
| Section / statement / impact / thank-you slides | Full Deep Blue `#265BA4`, white text |
| Cover | Photo fading into Sand on the left; title on the clean area; blue logo top-left |
| Title — content slide | Montserrat Bold 32pt `#265BA4` with a thin divider line under it |
| Title — section / closing | Montserrat Bold 45pt |
| Title — cover / hero | Montserrat Bold 51pt; Deep Blue on light photo area, white on dark |
| Secondary title | Montserrat Bold 18pt `#265BA4` |
| Body / bullets | Montserrat Regular ~17pt `#0B143E` |
| Footnotes / sources | Montserrat Regular 9–10pt `#666666` |
| Highlight band | Leaf Green `#27AE6F` box, white text |
| Feature circles | `#EAF4FC` on light, `#E3EEFD` on blue |
| Logo | Blue top-left on covers; small logo bottom-right on content, photo and split slides; round icon mark bottom-right beside a photo band |
| Photos | Reuse the template photoshoot first (warm interiors, mixed ages, AED case visible but secondary) |

Fewer words per slide is better. One idea per slide.

---

## 10. Photography and imagery

**Concept:** calm, readiness, vitality. Photography reassures, it does not sell.

- Safety is the foundation, not the subject; the system is the hero, not the product
- The AED is a background presence — mounted on a wall in a real space, never a flat lay or studio shot
- Red of the AED is muted in post (reference: `mute_red.py in.png out.png 0.65`)
- People are observed, not performing: no eye contact with camera, no posed emotion
- Inclusive casting across age and background; neutral clothing, no visible logos
- Composition: lots of negative space, straight horizon, eye level or slightly lower, medium-wide to wide
- Natural light only; colour balance warm grey, sand, off-white
- Styling palette: deep blues, terra, dark brown, green

**Sourcing order**

1. Company image bank on Drive (~251 real photos in scene folders: woningen, fysio, caroline, bouwkeet, kantoor, bar, auto, customercontact — select by folder, filenames are camera exports)
2. Photos inside the deck template
3. AI generation (Higgsfield `nano_banana_pro` with the red Philips HeartStart case reference) only when no real shot fits

Icons: simple line or flat icons in Deep Blue or Inkt on light surfaces; the three brand icons (people, planet, profit) exist as PNG assets.

---

## 11. Social and ad visuals (quick reference)

- Two locked tile styles: `panel` (photo plus Sand text panel) and `ugc` (full-bleed photo, scrim, white text)
- Sizes: feed 1080 × 1350, square 1080 × 1080, reel/story 1080 × 1920
- Mix Reels and carousels; pillars are peace-of-mind, education, social proof, team, offer
- Never fabricate testimonials; borrow competitor formats, never their USP
- Reels: animate the photo only (subtle push-in, silent), composite crisp text, add audio in-app
- French market: "vous", calm, minimal emoji, no exclamation marks

---

## 12. Email (transactional and sales)

- Max width 600px, background Sand, content card white with 15px radius
- Logo top-left, 140px wide
- Heading h3 size Deep Blue, body 16px Inkt, line-height 1.6
- One primary button, Deep Blue fill, 4px radius, 48px high, full-width on mobile
- Footer 12px `#666666`: company name, address, KvK, unsubscribe where applicable
- Fallback font stack applies; Montserrat via `@font-face` where the client supports it
- Any free text injected into an HTML email body must be escaped or allowlisted at the source — brand rules do not replace that control

---

## 13. Pre-delivery checklist

Verify before anything branded leaves the project

1. Montserrat is the only typeface
2. Headings Deep Blue `#2E61A6`, body Inkt `#1C2127` (deck body `#0B143E`)
3. No all-caps, no exclamation marks, no trailing periods on headings and bullets
4. Text left-aligned, line-height 1.6 in prose
5. Soft Rose appears only alongside Deep Blue or Inkt
6. Leaf Green used only for CTA and positive signals
7. Whitespace generous; 8px grid respected
8. Light surfaces are Sand or Background Blue; decks never use white slides
9. No backend mechanics or technical codes in user-facing copy
10. Tone is calm, human and reassuring; Invest copy has passed the compliance check
11. Logo untouched, correct variant for the background, clear space respected
12. Photos follow the sourcing order and the AED is secondary in frame

---

## 14. Ownership and change control

- Brand and design decisions: Mark (sign-off), Joshua (implementation in HubSpot and web)
- Copy and locale decisions: Kira
- Compliance on Invest communication: Peter and Bas Kok
- Proposed semantic colours (section 2.3) and the dense-UI type variant (section 3.3) are project defaults, not brand-book entries; log a D-series decision when a project adopts them and flag any deviation to Mark

*Source: Visual Identity Book P4a_final.pdf v1.1 (February 2026); P4A company deck template (August 2026); style-p4a skill v2026-09-25*
