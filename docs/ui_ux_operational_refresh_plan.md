# UI/UX Operational Refresh Plan

## Direction

Direction: Operational - Dense, high-contrast, fast-moving UI for cashier, kitchen, admin, and attendance workflows.

This application is an operations-first POS tool, so the redesign should optimize for:

- rapid scanning
- reliable touch targets on tablets
- high signal-to-noise information density
- consistent status feedback
- low-friction navigation across roles

## Current Diagnosis

The current product already has a usable dark operational tone, but the visual system is still fragmented.

- Global theme coverage is thin, so many screens hand-roll `InputDecoration`, button styles, dialogs, headers, and cards.
- Loading, empty, error, and offline states are inconsistent across features.
- Mobile information architecture is overloaded, especially in admin.
- Shared operational patterns exist, but they are not yet elevated into a reusable design system.

## Improvement Order

The implementation order below is intentional and should be followed top-to-bottom.

### 1. Foundation

Create a shared design system for:

- color tokens
- typography roles
- spacing and radius tokens
- panel, card, and dialog surfaces
- button variants
- form field styles
- common state views

Deliverables:

- `AppTheme`
- shared operational UI primitives
- global component theming

### 2. Layout Shells

Normalize the visual shell used across the app:

- sidebar and top bar
- page section headers
- status badges
- offline messaging
- page-level padding and panel rhythm

Deliverables:

- web sidebar cleanup
- reusable surface containers
- reusable page header pattern

### 3. Entry Experience

Refresh the lowest-context screens first so the system feels coherent before users enter operational flows.

- login
- onboarding

Goals:

- stronger brand framing
- clearer hierarchy
- better input affordance
- explicit loading and error handling

### 4. Core Operational Flows

Refresh the highest-value operational screens next.

- admin tables and order workspace
- cashier
- kitchen
- attendance kiosk

Goals:

- faster scanning
- stronger grouping
- better status color usage
- clearer primary actions
- more consistent empty, error, and success states

### 5. Remaining Feature Surfaces

Propagate the system into:

- reports
- inventory
- QC
- settings
- remaining admin tabs

### 6. Verification

Validate the redesign against role-based scenarios:

- login to role landing page
- table selection to order creation
- kitchen item progression
- payment completion
- attendance capture
- offline and retry behavior

## Visual Rules

### Typography

- Display labels use `Bebas Neue`.
- Body and form text use `Noto Sans KR`.
- Currency, counts, and timestamps should use a monospace numeric treatment where practical.
- Limit each screen to title, body, and caption tiers.

### Color

- Preserve the amber brand anchor.
- Use semantic status colors for available, warning, success, and destructive actions.
- Avoid introducing new accent families unless tied to a semantic status.

### Spacing

- Operational surfaces use a 4px or 8px rhythm.
- Panels should feel compact but not cramped.
- Tablet touch targets should remain comfortable even in dense layouts.

### States

Every interactive screen must have:

- loading
- empty
- error
- disabled
- offline awareness where relevant

## Refactor Rules

- Prefer shared primitives over per-screen styling.
- Preserve existing business logic and providers while redesigning presentation.
- Change structure only where it materially improves workflow clarity.
- Keep the established dark operational tone; refine it rather than replacing it.
