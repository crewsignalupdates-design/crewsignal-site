# CrewSignal GA4-R1 review

This branch prepares readership measurement for GA4 stream `G-JM4GBY4EQY`. The source was reviewed against `main` at `7f66ac8`. Collection is disabled in a default build. The production build flag is described below.

## Implementation and changed files

| File | Change |
| --- | --- |
| `netlify.toml` | Runs the site build and publishes `dist`. All existing site-wide header directives are preserved. |
| `package.json`, `scripts/build-site.mjs` | Copy the public tree into a clean output directory and add one shared stylesheet and one deferred consent script to each eligible HTML page. Generate the analytics path from the source file and honor existing exact lowercase Netlify aliases. |
| `public/assets/js/analytics-consent.js` | Add the consent controls, persist the choice, load the measurement frame after approval and affirmative consent, and handle withdrawal, storage failures, and changes across tabs. |
| `public/assets/css/analytics-consent.css` | Provide equal controls with visible focus, mobile wrapping, and a 44 px minimum target height. Keep the prompt in the page flow and hide the controls when printing. |
| `public/assets/analytics-frame.html`, `public/assets/js/analytics-frame.js` | Run direct `gtag.js` in a separate same-origin document with a scoped CSP and no-referrer policy. Pass only a build-generated page path to Google Analytics. |
| `public/privacy/index.html` | Explain the purpose, optional consent, local choice, first-party cookies and their 90-day expiry, withdrawal, two-month GA4 retention, and Google processing. Link to Google's partner-site notice and opt-out add-on. |
| `scripts/test-ga4-browser.py` | Exercise a built copy in Chromium using the genuine Google tag script and intercept every Google request before it leaves the browser. |
| `docs/ga4-r1-review.md` | Record coverage, verification, release conditions, and rollback. |

### Consent and data

The default Consent Mode v2 command denies all four consent types. The consent update grants only `analytics_storage`. The browser requests the Google tag only after the accepted choice can be read back from first-party local storage and the production build and origin checks both pass. Fresh visits, declines, and unavailable or read-only local storage leave analytics off. Users can read every page and use site features without making a choice.

Privacy Preferences is available at the bottom of each instrumented page. Decline stops measurement by setting Google's per-stream disable flag and removing its frame. It expires `_ga` and `_ga_JM4GBY4EQY` for the root path, including host-only and domain-scoped variants. The preference is applied in other open site tabs through storage events and rechecked on page restoration and visibility changes. Accepting again starts a new measurement frame.

The measurement frame has a fixed title and starts without a referrer. It uses a published pathname generated at build time. Visitor query strings, fragments, referring URLs, form fields, and link destinations are never passed to the frame by the site's code. The main document does not execute the Google tag. The integration explicitly disables Google signals, ad personalization signals, display features, enhanced conversions, and URL passthrough. It does not provide a User-ID, visitor-supplied fields, or event listeners for forms or links. The Google tag may supply standard technical and session fields. The analytics cookies are host-only, Secure, SameSite=Strict, and set to expire 90 days after they are first written.

### CSP

The site-wide HTTP CSP stays `upgrade-insecure-requests`, as verified on production during the baseline review. The following meta CSP applies only to the measurement frame.

```text
default-src 'none';
script-src 'self' https://www.googletagmanager.com/gtag/js;
connect-src https://www.google-analytics.com/g/collect https://region1.google-analytics.com/g/collect;
img-src https://www.google-analytics.com/g/collect https://region1.google-analytics.com/g/collect;
base-uri 'none';
form-action 'none'
```

The frame's same-origin bootstrap and the direct Google tag are the only script sources. The two path-scoped collector URLs support background and image-based measurement transports and the regional collector. The frame uses `no-referrer` for both loading and outgoing requests. The site-wide HSTS, framing, MIME, browser permissions, referrer, and cache directives are preserved. The hostname `www.googletagmanager.com` serves Google's direct tag at `/gtag/js`. There is no GTM bootstrap or `/gtm.js` request. A GTM identifier appears as metadata inside Google's current script response. The frame CSP does not authorize loading that container.

## Coverage and verification

| Public content | Consent integration |
| --- | ---: |
| Negotiations and Mediation | 390 |
| Merger and Integration | 232 |
| Union Governance | 75 |
| Contract Architecture | 59 |
| Home, contact, privacy, and subscription journey | 7 |
| **Total** | **763** |

The build audited 775 HTML files, including the new support frame. It excluded six immediate redirects, four empty or BOM-only placeholders, the unfilled Mediation template, and the analytics frame. Historical reports, permanent components, carrier landing pages, and valid future HTML under `public/` are covered. PDFs, raw assets, and off-site pages have no integration. Run `node scripts/build-site.mjs --coverage-json` for every included and excluded path.

Automated verification compared all 860 files in `dist` with their source counterparts in both build modes. Removing the generated tags produced byte-for-byte equality for each instrumented file. Other files matched directly, including `_redirects`. The check confirmed one integration per instrumented page, the exact-case United carrier rewrite, preservation of all baseline Netlify headers, and no report source changes. A disposable build picked up a newly added weekly page and dropped it after the source file was removed. The existing PowerShell weekly generator was reviewed but could not be run end to end because its tracked HTML template on `main` is empty. This integration instruments any valid page the publishing workflow places under `public/`.

Chromium 156 tested a clean browser, positive and negative choices, returning visits, navigation, a later change of mind, withdrawal in two tabs, cookie deletion, and storage that throws on read or write. It exercised keyboard focus, the skip link, Escape, and equal mobile choices at 320 px. The test used rendered home, subscription and contact pages, as well as all four research sections. Research samples included United's carrier landing page, the Alaska–Hawaiian permanent tracker and November 20 report, Air Wisconsin's permanent and November 20 Mediation pages, and the CWA funding and dues component. Existing inline report print behavior and the Endeavor smart-back link passed, as did the Mailchimp form action and configured headers. The test cancels local form submission and uses synthetic fields.

Network inspection found zero Google requests before consent, after decline and subsequent navigation, and following withdrawal and reload. The main accepted-traffic audit captured 12 page views and inspected 15 measurement payloads. It found one page view per tested navigation, the correct stream and published path, empty referrers, advertising storage denied, and non-personalized ads indicated by `npa=1`. The first two consent commands confirmed that all three advertising fields stayed denied. The captured requests contained no test names, email addresses, query values, fragments, referrer, form payloads, outbound URLs, User-ID, or user-provided data. No ad or GTM endpoints were contacted. The default build and preview-origin checks produced zero Google requests even after accepting.

The browser test used a captured, unmodified `gtag.js` response from Google. It intercepted collect requests before they reached GA4. Its SHA-256 for this review was `575a4b00ce0d4839e711836342157ab69fdcec0252ea3d053727900a412b1212`. The current stream emitted a GA4 `scroll` event after acceptance, and Google's tag response advertised automatic event and user-provided data capabilities. The branch has a disabled-by-default production gate because these settings must be checked in the stream and connected Google tag before enabling collection. GA4 reporting, live Netlify deployment, and account-only settings were outside the local test.

### Reproduce the browser checks

Use Python 3.11 or later with Playwright and Chromium. Set `CHROMIUM_EXECUTABLE` if using system Chromium.

```sh
curl -fsS 'https://www.googletagmanager.com/gtag/js?id=G-JM4GBY4EQY' -o /tmp/crewsignal-gtag.js
CREWSIGNAL_GA4_APPROVED=1 npm run build
python3 scripts/test-ga4-browser.py /tmp/crewsignal-gtag.js
npm run build
python3 scripts/test-ga4-browser.py /tmp/crewsignal-gtag.js --disabled
```

The suite permits the current stream's observed scroll event so reviewers can exercise the code before the Google account is prepared. Production verification requires that enhanced events are absent. Google may change its tag implementation or endpoint behavior. Recheck the current response and network behavior at release.

## Production verification after explicit release approval

1. In GA4 Admin, verify the correct web stream and measurement ID. Disable Enhanced Measurement, including automatic form interactions, outbound clicks, scroll, site search, video, downloads, and browser-history page views. Check the connected Google tag's automatic event detection and user-provided data settings and turn those features off. Confirm Google signals and personalized advertising are off and that no advertising destination is linked. Confirm email and sensitive-query redaction and set user/event data retention to two months with reset on new activity disabled.
2. Repeat the approved-mode Chromium check with a fresh tag capture and append `--release` to the Python command. Confirm that the browser records one explicit `page_view` per instrumented navigation and zero enhanced-measurement or user-data events. Check Google tag settings again if enhanced events remain. Standard GA4 engagement and session fields may still appear. Keep production collection disabled until this check passes.
3. On explicit approval to deploy, set `CREWSIGNAL_GA4_APPROVED=1` on the Netlify production build only. Confirm Netlify runs `npm run build` and serves `dist`. Review the Privacy Policy effective date at release.
4. In a fresh browser on the live canonical HTTPS site, open Developer Tools with network log preservation enabled. Verify no tag or collector requests or GA cookies on fresh, declined, and returning-declined visits. Validate live headers, representative routes in all four research sections, and the contact, subscription, and mobile navigation flows.
5. Accept and inspect the script URL and each payload. Confirm the exact stream ID, a published page path without a query or fragment, no referrer or visitor-provided fields, and denied advertising consent. Confirm the event in GA4 Realtime. In a second tab, withdraw via Privacy Preferences, verify both cookies are removed, and confirm that later navigation and reloads have no tag or collector requests. Verify mobile and keyboard interaction using the current production build.

### Rollback

Remove `CREWSIGNAL_GA4_APPROVED` from the production build environment and rebuild the approved release to stop new tag loads while retaining the preferences UI and cookie cleanup. For a full rollback, use the last approved pre-GA4 Netlify deploy or revert the GA4-R1 commit and restore the `public` publish path in the same revert. Verify the prior site headers and public routes, and confirm zero GA scripts and collect requests in a fresh session. Any cookie already issued to a browser that never withdraws can persist until expiry. Rollback and withdrawal apply to future collection and do not alter events Google has already received.
