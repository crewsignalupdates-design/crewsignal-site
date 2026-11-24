"""Run against an approved-mode local build using a captured Google tag script.

Usage: python3 scripts/test-ga4-browser.py /path/to/gtag.js
Requires Python 3.11+, Playwright and Chromium (or CHROMIUM_EXECUTABLE).
All Google requests from the test browser are intercepted.
"""

import mimetypes
import os
from pathlib import Path
import sys
import time
import tomllib
from urllib.parse import parse_qs, unquote, urlsplit

from playwright.sync_api import expect, sync_playwright


ROOT = Path(__file__).resolve().parents[1]
ORIGIN = "https://crewsignal.org"
KEY = "crewsignal.analytics-consent.v1"
COOKIES = {"_ga", "_ga_JM4GBY4EQY"}
TAG_URL = "https://www.googletagmanager.com/gtag/js?id=G-JM4GBY4EQY"
COLLECTORS = {"www.google-analytics.com", "region1.google-analytics.com"}
HEADERS = tomllib.loads((ROOT / "netlify.toml").read_text())["headers"][0]["values"]
REWRITES = {}
for line in (ROOT / "dist/_redirects").read_text().splitlines():
    fields = line.split()
    if len(fields) == 3 and fields[2] == "200":
        REWRITES[fields[0]] = fields[1]

TAG = Path(sys.argv[1]).read_bytes()
REPRESENTATIVES = (
    "/",
    "/reports/contract-architecture/cwa-afa/united/",
    "/reports/merger-integration/trackers/alaska-hawaiian/",
    "/reports/merger-integration/trackers/alaska-hawaiian/weekly/2026.11.20.html",
    "/reports/mediation/negotiations/air-wisconsin/",
    "/reports/mediation/trackers/air-wisconsin/2026.11.20/",
    "/reports/union-governance/cwa/6-funding-and-dues/",
    "/privacy/",
    "/contact/",
    "/subscribe/",
)
MARKERS = (
    "QaPrivateName", "qa-private@example.invalid", "QaPrivateFragment",
    "QaPrivateCampaign", "QaPrivateReferrer", "QaPrivateClick", "QaPrivateMessage",
)


def site_response(route):
    url = urlsplit(route.request.url)
    path = unquote(REWRITES.get(url.path, url.path))
    file = ROOT / "dist" / path.lstrip("/")
    if file.is_dir():
        file /= "index.html"
    if not file.is_file():
        route.fulfill(status=404)
        return
    route.fulfill(path=file, headers={
        **HEADERS,
        "Content-Type": mimetypes.guess_type(file)[0] or "application/octet-stream",
    })


def preferences(page):
    return page.get_by_role("button", name="Privacy Preferences", exact=True)


def accept(page):
    return page.get_by_role("button", name="Accept analytics", exact=True)


def decline(page):
    return page.get_by_role("button", name="Decline analytics", exact=True)


def wait_for(page, check):
    for _ in range(100):
        if check():
            return
        page.wait_for_timeout(100)
    raise AssertionError("Timed out waiting for browser traffic or state")


def payloads(traffic):
    for url, body, _ in traffic:
        if urlsplit(url).netloc not in COLLECTORS:
            continue
        base = parse_qs(urlsplit(url).query, keep_blank_values=True)
        for line in (body or "").splitlines() or [""]:
            yield {key: values[0] for key, values in
                   (base | parse_qs(line, keep_blank_values=True)).items()}


def views(traffic):
    return [event for event in payloads(traffic) if event.get("en") == "page_view"]


def analytics_cookies(context):
    return [cookie for cookie in context.cookies() if cookie["name"] in COOKIES]


def browser_context(browser, **options):
    context = browser.new_context(service_workers="block", **options)
    traffic, errors = [], []

    def route_request(route):
        request = route.request
        url = urlsplit(request.url)
        if url.netloc in {"crewsignal.org", "preview.crewsignal.invalid"}:
            site_response(route)
        elif request.url == TAG_URL:
            route.fulfill(body=TAG, content_type="application/javascript")
        else:
            route.fulfill(status=204, headers={"Access-Control-Allow-Origin": "*",
                                               "Access-Control-Allow-Methods": "*",
                                               "Access-Control-Allow-Headers": "*"})

    def inspect(request):
        url = urlsplit(request.url)
        if "google" in url.netloc or "doubleclick" in url.netloc:
            traffic.append((request.url, request.post_data, request.headers))

    def monitor(page):
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("console", lambda msg: errors.append(msg.text)
                if msg.type == "error" and "Content Security Policy" in msg.text else None)

    context.route("**/*", route_request)
    context.on("request", inspect)
    context.on("page", monitor)
    return context, traffic, errors


def assert_quiet(context, page, traffic):
    page.wait_for_timeout(450)
    assert not traffic, traffic
    assert not analytics_cookies(context)
    assert len(page.frames) == 1


def verify_storage_failures(browser):
    for blocked in ("getItem", "setItem"):
        context, traffic, errors = browser_context(browser)
        context.add_init_script(f"""(() => {{
            if (location.origin !== {ORIGIN!r}) return;
            localStorage.setItem({KEY!r}, "accepted");
            Storage.prototype.{blocked} = () => {{ throw new Error("Storage blocked"); }};
        }})();""")
        page = context.new_page()
        page.goto(ORIGIN)
        expect(accept(page)).to_be_visible()
        accept(page).click()
        expect(page.get_by_role("status")).to_contain_text("Analytics is off")
        assert_quiet(context, page, traffic)
        page.reload()
        expect(accept(page)).to_be_visible()
        assert_quiet(context, page, traffic)
        assert not errors, errors
        context.close()


def verify_mobile_and_decline(browser):
    context, traffic, errors = browser_context(
        browser, viewport={"width": 320, "height": 690}, is_mobile=True, has_touch=True,
    )
    page = context.new_page()
    response = page.goto(ORIGIN)
    for key, value in HEADERS.items():
        assert response.headers[key.lower()] == value
    assert_quiet(context, page, traffic)
    page.keyboard.press("Tab")
    expect(page.get_by_role("link", name="Skip to content")).to_be_focused()
    page.keyboard.press("Tab")
    expect(page.get_by_role("link", name="Privacy Policy").first).to_be_focused()
    page.keyboard.press("Tab")
    expect(accept(page)).to_be_focused()
    page.keyboard.press("Tab")
    expect(decline(page)).to_be_focused()
    buttons = [button.bounding_box() for button in (accept(page), decline(page))]
    assert buttons[0]["width"] == buttons[1]["width"]
    assert all(box["height"] >= 44 and box["x"] + box["width"] <= 320 for box in buttons)
    assert buttons[0]["y"] + buttons[0]["height"] <= buttons[1]["y"]
    assert page.evaluate("document.documentElement.scrollWidth") <= 320
    page.keyboard.press("Enter")
    expect(page.locator("main")).to_be_focused()
    expect(accept(page)).not_to_be_visible()
    expect(page.get_by_role("navigation", name="Main navigation")).to_be_visible()
    assert page.evaluate("(key) => localStorage.getItem(key)", KEY) == "declined"
    assert_quiet(context, page, traffic)
    returning = context.new_page()
    returning.goto(ORIGIN + "/reports/mediation/")
    expect(accept(returning)).not_to_be_visible()
    assert_quiet(context, returning, traffic)
    preferences(returning).focus()
    returning.keyboard.press("Enter")
    expect(returning.get_by_role("heading", name="Analytics preferences")).to_be_focused()
    returning.keyboard.press("Escape")
    expect(preferences(returning)).to_be_focused()
    for path in ("/subscribe/", "/reports/mediation/negotiations/air-wisconsin/"):
        returning.goto(ORIGIN + path)
        preferences(returning).click()
        for button in (accept(returning), decline(returning)):
            box = button.bounding_box()
            assert 0 <= box["x"] and box["x"] + box["width"] <= 320
        assert_quiet(context, returning, traffic)
    assert not errors, errors
    context.close()


def verify_acceptance_and_withdrawal(browser):
    context, traffic, errors = browser_context(browser)
    page = context.new_page()
    page.goto(
        ORIGIN + "/subscribe/?email=qa-private%40example.invalid"
        "&utm_campaign=QaPrivateCampaign&gclid=QaPrivateClick#QaPrivateFragment",
        referer="https://example.invalid/QaPrivateReferrer?name=QaPrivateName",
    )
    assert_quiet(context, page, traffic)
    assert page.locator("form").get_attribute("action").startswith("https://crewsignal.us19.list-manage.com/")
    accept(page).click()
    wait_for(page, lambda: len(views(traffic)) == 1)
    assert len(page.frames) == 2
    frame = page.frames[1]
    commands = frame.evaluate('window.dataLayer.map(command => Array.from(command))')
    assert commands[0][:2] == ["consent", "default"]
    assert commands[0][2] == dict.fromkeys(
        ["analytics_storage", "ad_storage", "ad_user_data", "ad_personalization"], "denied")
    assert commands[1] == ["consent", "update", commands[0][2] | {"analytics_storage": "granted"}]
    assert not frame.evaluate("document.referrer")
    cookies = analytics_cookies(context)
    assert {cookie["name"] for cookie in cookies} == COOKIES, cookies
    for cookie in cookies:
        assert cookie["secure"] and cookie["sameSite"] == "Strict"
        assert cookie["domain"] == "crewsignal.org" and cookie["path"] == "/"
        assert abs(cookie["expires"] - time.time() - 90 * 86400) < 120
    page.locator("form input[type=email]").fill("qa-private@example.invalid")
    page.evaluate("""() => {
        const form = document.querySelector('form');
        const field = document.createElement('textarea');
        field.name = 'message';
        field.value = 'QaPrivateMessage';
        form.append(field);
        form.addEventListener('submit', event => event.preventDefault(), {once:true});
        form.dispatchEvent(new Event('submit', {bubbles:true,cancelable:true}));
        const link = document.createElement('a');
        link.href = 'https://example.invalid/QaPrivateName';
        link.addEventListener('click', event => event.preventDefault());
        document.body.append(link);
        link.click();
    }""")
    page.wait_for_timeout(5600)
    assert len(views(traffic)) == 1
    expected_paths = ["/subscribe/"]
    for path in REPRESENTATIVES:
        assert page.goto(ORIGIN + path).ok
        expected_paths.append(path)
        wait_for(page, lambda: len(views(traffic)) >= len(expected_paths))
        expect(preferences(page)).to_be_visible()
        expect(accept(page)).not_to_be_visible()
        assert len(page.frames) == 2
    returning = context.new_page()
    returning.goto(ORIGIN + "/thanks/")
    expected_paths.append("/thanks/")
    wait_for(returning, lambda: len(views(traffic)) >= len(expected_paths))
    assert [event["dl"] for event in views(traffic)] == [ORIGIN + path for path in expected_paths]
    preferences(returning).click()
    # Let the current stream's pre-withdrawal automatic events finish.
    returning.wait_for_timeout(5600)
    for url, body, headers in traffic:
        parts = urlsplit(url)
        assert url == TAG_URL or (parts.netloc in COLLECTORS and parts.path == "/g/collect"), (url, errors)
        assert not headers.get("referer")
        raw = unquote(url + (body or ""))
        assert all(marker not in raw for marker in MARKERS)
    events = list(payloads(traffic))
    allowed_events = {"page_view", "user_engagement"}
    if "--release" not in sys.argv[2:]:
        allowed_events.add("scroll")
    for event in events:
        assert event["gcs"] == "G101" and event["npa"] == "1"
        assert "gcd" in event and event["tid"] == "G-JM4GBY4EQY"
        assert not event.get("dr")
        assert event["dl"] in {ORIGIN + path for path in expected_paths}
        assert set(event).isdisjoint({"uid", "em", "up.user_id", "ep.link_url", "ep.form_destination"})
        assert event["en"] in allowed_events, event["en"]
    # Test both the host-only cookies used now and domain-scoped legacy variants.
    context.add_cookies([
        {"name": name, "value": "legacy", "domain": ".crewsignal.org", "path": "/", "secure": True}
        for name in COOKIES
    ])
    assert len(analytics_cookies(context)) == 4
    before = len(traffic)
    decline(returning).evaluate("(button) => button.click()")
    wait_for(page, lambda: len(page.frames) == 1)
    assert len(returning.frames) == 1
    assert not analytics_cookies(context)
    returning.reload()
    expect(accept(returning)).not_to_be_visible()
    returning.wait_for_timeout(800)
    assert not traffic[before:], list(payloads(traffic[before:]))
    page.close()
    preferences(returning).click()
    accept(returning).click()
    wait_for(returning, lambda: len(views(traffic[before:])) == 1)
    assert views(traffic[before:])[0]["dl"] == ORIGIN + "/thanks/"
    assert not errors, errors
    print(f"Verified {len(expected_paths)} page views and inspected {len(events)} measurement payloads.")
    print("Captured stream event types:", ", ".join(sorted({event["en"] for event in events})))
    context.close()


def verify_disabled_build(browser):
    context, traffic, errors = browser_context(browser)
    page = context.new_page()
    context.add_cookies([
        {"name": name, "value": "legacy", "domain": ".crewsignal.org", "path": "/", "secure": True}
        for name in COOKIES
    ])
    page.goto(ORIGIN)
    accept(page).click()
    assert page.evaluate("(key) => localStorage.getItem(key)", KEY) == "accepted"
    assert_quiet(context, page, traffic)
    page.reload()
    assert_quiet(context, page, traffic)
    assert not errors, errors
    context.close()


def verify_controls_and_exclusions(browser):
    context, traffic, errors = browser_context(browser)
    page = context.new_page()
    page.goto(ORIGIN + "/assets/analytics-frame.html")
    assert_quiet(context, page, traffic)
    page.goto("https://preview.crewsignal.invalid/")
    accept(page).click()
    assert_quiet(context, page, traffic)

    page.goto(ORIGIN + "/reports/contract-architecture/criteria/")
    detail = page.locator("#reserve-pilot-r19")
    assert detail.get_attribute("open") is None
    page.evaluate("dispatchEvent(new Event('beforeprint'))")
    assert detail.get_attribute("open") is not None
    page.evaluate("dispatchEvent(new Event('afterprint'))")
    assert detail.get_attribute("open") is None

    page.goto(ORIGIN + "/reports/mediation/")
    page.goto(
        ORIGIN + "/reports/contract-architecture/cwa-afa/endeavor/",
        referer=ORIGIN + "/reports/mediation/",
    )
    assert page.locator("#cs-smart-back").get_attribute("href") == "/reports/mediation/"
    page.locator("#cs-smart-back").click()
    page.wait_for_url(ORIGIN + "/reports/mediation/")
    assert_quiet(context, page, traffic)
    assert not errors, errors
    context.close()


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(executable_path=os.getenv("CHROMIUM_EXECUTABLE"))
    print("Chromium", browser.version)
    if "--disabled" in sys.argv[2:]:
        verify_disabled_build(browser)
    else:
        verify_mobile_and_decline(browser)
        verify_storage_failures(browser)
        verify_acceptance_and_withdrawal(browser)
        verify_controls_and_exclusions(browser)
    browser.close()

print("GA4 browser checks passed.")
