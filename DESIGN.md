# YappYapp Brutal Design System

YappYapp is a 440 by 596 point local macOS dictation console. Its only visual register is Brutal: warm paper, near-black warm ink, saturated state colors, two-point frames, hard four-point offsets, and dense uppercase type.

## Identity

- Preserve the **MIC / FILES / MODELS / WORDS / PET / SETUP** information architecture. File transcription lives on FILES, not MIC.
- Keep the warm-paper poster character. Personality is functional: recording, readiness, setup, and model state must read in one glance.
- Use only flat fills, hard edges, and hard offset shadows. Never add translucency, blur, gradients, glow, soft shadow, or generic rounded-card styling.
- Keep the fixed popover geometry. Tabs own vertical scrolling so scaled and multilingual content stays reachable.

## Tokens

`BrutalDesignSystem.swift` is the source of truth for palette, type scaling, geometry, interaction, and reusable controls.

- Paper: `Color(0.96, 0.94, 0.88)`
- Card: `Color(0.99, 0.98, 0.94)`
- Field: `Color(0.995, 0.985, 0.95)`
- Ink: `Color(0.035, 0.027, 0.020)`
- State fills: yellow, red, blue, and green from the shipped identity
- Frame: 2 points
- Hard offset: 4 points

Semantic foreground roles must meet WCAG AA (4.5:1) for small text on paper, card, and field. Use ink on yellow, red, and green fills; use paper on blue and ink fills. Muted readable text uses the semantic ink roles: secondary is ink at 68%, tertiary and disabled are ink at 60%. Blue may carry text on paper and card (4.6:1 or better). Red and green are fills only, never text on paper; use `dangerText` and `successText` instead.

## Typography

Setup sets type only through the six `BrutalTextStyle` roles in `BrutalDesignSystem.swift`. One family (the system sans) in two weights; captions are the only sentence-case role.

| Role | Size | Weight | Tracking | Case | Use |
|---|---|---|---|---|---|
| sectionTitle | 9.5 | black | 1.2 | caps | ink header bar |
| rowLabel | 10 | black | 0.8 | caps | the name of a setting |
| control | 9 | black | 0.6 | caps | text inside segments, switches, buttons, menus, fields |
| value | 10 | black | 0.6 | caps | a live reading beside a label (5MIN, GOOD) |
| caption | 9.5 | medium | 0 | sentence | help and status under a row |
| action | 11 | black | 0.8 | caps | primary action buttons |

Other tabs keep their shipped weight, design, tracking, and capitalization. Every `brutalFont` call resolves its size through `BrutalTypeScale`, which applies two rules everywhere:

- **Text size setting.** SETUP > APP > TEXT SIZE offers SMALL (0.9x), DEFAULT (1x), LARGE (1.15x), and LARGER (1.3x). The choice is stored as `textSize` in config.json; older configs without the key render at DEFAULT. macOS does not drive Dynamic Type, so this setting is the in-app way to grow type. An explicit Dynamic Type size still multiplies in, capped at 1.6x combined.
- **9pt floor.** No label renders below 9 points at any setting. Sizes at or above the floor keep their shipped value at DEFAULT.

Compact labels may grow and wrap at larger sizes. The popover keeps its fixed 440 by 596 frame; every tab body scrolls (`BrutalScroll`), so nothing becomes unreachable.

## Components

- Setup has one representation per kind of choice (`BrutalSetupControls.swift`), all 26 points tall in the 2-point ink frame: `BrutalSegmented` for pick one of a few (equal cells on one line), `BrutalPicker` for pick one of many (an inline dropdown), `BrutalSwitch` for on or off, `BrutalShortcutField` for a key combo (click, press keys, x clears), `BrutalSlider` for a range, `BrutalActionButton` for secondary actions and `BrutalDisclosure` for rarely changed rows. Compact controls sit right of their label; wide ones sit under it.
- Native buttons retain native accessibility button roles and actions.
- Interactive controls expose contextual labels, hints, values, selected state, and disabled state.
- Keyboard focus paints the Brutal focus ring: a hard 2-point blue frame, 4 points outside the control with a paper gap between. No glow, blur, or rounded corners. Native macOS focus effects stay suppressed. Focus that arrives under the pointer (a click) stays unpainted, so the ring marks keyboard navigation only. Buttons get the ring through `brutalInteractive` and `brutalKeyboardAction`; native fields and sliders use `brutalFocusRing()`.
- VoiceOver hears phase changes (listening, transcribing, needs attention) and every paste outcome through one route, `AccessibilityAnnouncer`. The paste outcome speaks its status line and suppresses the matching phase announcement. The announcer is silent during the self-test.
- Visual controls keep their shipped size. Their hit shapes expand to at least 44 points where layout permits.
- Text fields and editors have programmatic labels. Selection controls expose their current value.
- Model selection, download, and cancellation are sibling controls, never nested buttons.
- Transcript expansion is keyboard and VoiceOver operable.
- Reduce Motion freezes decorative waveform interpolation while preserving state.

## Responsive and Content Rules

- No core tab may become unreachable at LARGER text size or maximum Dynamic Type.
- Settings section headers are a full-width ink bar, flush with the frame. A text-width bar lets the drop shadow show a paper hairline.
- Long status, error, model, and multilingual copy wraps instead of truncating.
- Compact alternatives may reflow vertically when horizontal space is insufficient.
- Decorative pet art stays hidden from accessibility and never blocks scroll reach.
- Empty, loading, installed, offline, permission, recording, transcribing, success, and error states keep explicit text, not color alone.

## Anti-Patterns

- No alternate visual-mode selector.
- No soft SaaS cards, native Settings clone, neon AI palette, gradient text, translucent effects, or decorative motion.
- No em dashes in user-facing copy.
