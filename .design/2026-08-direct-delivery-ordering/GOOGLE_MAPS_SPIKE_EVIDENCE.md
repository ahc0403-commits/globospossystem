# Google Maps address spike evidence

Status: source and no-provider-traffic verification complete; real Google test
project, device matrix, usage, and cost evidence pending. The direct storefront
remains disabled and no Google key is stored in the repository.

## Implemented source contract

- The browser never requests geolocation on page load. `Use current location`
  is an explicit customer action available in direct-map mode.
- A successful browser position moves the direct map and must pass server-side
  reverse geocoding before it becomes a confirmed delivery coordinate.
- Permission denial, unsupported geolocation, provider unavailability, and
  timeout keep the store-center/manual-pin path available. They do not submit
  or confirm an address.
- Address autocomplete creates a UUIDv4 Places session token at search start,
  reuses it for all autocomplete keystrokes and the terminating Place Details
  request, then discards it. Clearing/abandoning a search also discards it.
- The Edge boundary passes `sessionToken` to Places Autocomplete (New) and the
  same `sessionToken` query parameter to Place Details (New). Field masks remain
  limited to prediction ID/text and detail ID/formatted address/location/address
  components.
- Missing server key fails before provider traffic. HTTP 400/429/5xx, timeout,
  malformed JSON, invalid detail coordinates, empty reverse-geocode results,
  and invalid predictions use safe public outcomes without leaking Google
  payloads.
- Cached exact address data remains device/store scoped and requires a new map
  confirmation before submission. Stale async autocomplete/detail/location
  results cannot replace newer customer input.

## Local verification

Captured: 2026-08-21

- Deno format/lint/type check and 19 Edge tests: pass.
- Focused Flutter analysis: pass.
- Direct Flutter suites: 23 tests pass, including:
  - address surfaces at 390x844, 768x1024, 1024x768, and 1440x900;
  - no automatic geolocation request;
  - successful location -> camera move -> reverse geocode;
  - permission denied, timeout, unavailable, and unsupported fallbacks;
  - semantic labels/live announcements for the map/location controls;
  - paired/rotated/abandoned Places tokens and stale response suppression;
  - cached-address reconfirmation and Maps JS load failure.
- No live Google request, customer location, or customer address was used.

## Required flag-off Google test project (not yet executed)

Before any storefront can be enabled:

1. Create one non-production Google Cloud project and attach a billing account.
2. Enable only Maps JavaScript API, Places API (New), and Geocoding API.
3. Create a browser key restricted to Maps JavaScript API and the exact private
   test referrers. Create a separate server key restricted to Places API (New)
   and Geocoding API using the supported server-side application restriction.
4. Store `GOOGLE_MAPS_BROWSER_KEY` and `GOOGLE_MAPS_SERVER_API_KEY` only in the
   approved deployment secret store. Never add them to source, build logs, or
   Flutter assets.
5. Set per-API daily quotas, a project budget, and escalating budget alerts
   approved by the owner before issuing requests.
6. Keep the storefront flag off and the Google Business Profile link absent.

No step in this section has been claimed as complete.

## Real-browser matrix (pending)

Run on Android Chrome, iPhone Safari, desktop Chrome, and desktop Safari with
synthetic Vietnamese test addresses only. Cover full-address paste, building
search, apartment detail, suggestion selection, pin refinement, direct pin,
current-location allow/deny, cached address reconfirmation, and forced
quota/network/API failure. Record browser/OS, result, sanitized latency, and
request counts; never record exact personal coordinates.

## Usage, quality, and go/no-go reconciliation (pending)

For every completed and abandoned search, reconcile autocomplete and details
requests by session-token metrics. Confirm no Pro/Enterprise field outside the
documented masks is requested. The provisional go/no-go gate is:

- 100% completed searches have one paired token and abandoned searches have no
  terminating details call;
- zero unconfirmed coordinates can be submitted;
- synthetic-address success and p95 latency meet the owner-approved operating
  targets on all required browsers;
- projected monthly API cost stays within the owner-approved monthly cap and
  quota/budget alerts are observed in the test project.

Numerical success, latency, and currency thresholds require business approval
and actual Google metrics; they are intentionally not fabricated here.
