"""Offline UI-only smoke test. No native APIs; serves checked-out Pages HTML."""
import http.server
import functools
import pathlib
import shutil
import threading
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1] / "docs"
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT)))
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/index.html"
try:
    with sync_playwright() as p:
        executable = shutil.which("google-chrome") or shutil.which("chromium")
        browser = p.chromium.launch(headless=True, executable_path=executable, args=["--no-sandbox"]) if executable else p.chromium.launch(headless=True)
        context = browser.new_context(viewport={"width": 1440, "height": 960})
        context.route("**/*", lambda route: route.continue_() if route.request.url.startswith(f"http://127.0.0.1:{server.server_port}/") else route.abort())
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(url)
        page.wait_for_selector("[data-page=home]")
        assert page.locator("[data-page]").count() == 32
        for name in page.locator("[data-page]").evaluate_all("(xs) => xs.map(x => x.dataset.page)"):
            page.locator(f'[data-page="{name}"]').click()
            assert page.locator("main h1").count() == 1, name
        page.locator('[data-page="tests"]').click()
        page.locator('[data-v4="extendedChecks"]').click()
        assert page.evaluate("runChecks.length") == 71
        assert page.evaluate("runChecks.every(x => x.ok)")
        print("PASS: 32 desktop navigations and 71 browser-executed state checks")
        page.locator('[data-page="profiles"]').click()
        page.locator('[data-sim="profile:2"]').click()
        page.locator('[data-page="builder"]').click()
        page.locator('[data-v4="goGraph"]').click()
        assert page.locator(".v5graph svg path").count() > 0
        page.locator('[data-v4="graphApply"]').click()
        assert page.evaluate("S.routes.length") == 5
        page.locator('[data-page="layouteditor"]').click()
        page.get_by_role("button", name="Reload saved layout", exact=True).click()
        assert page.locator("[data-widget]").count() == 5
        first_widget = page.locator("[data-widget]").first.get_attribute("data-widget")
        page.locator(f'[data-v4="layoutDown:{first_widget}"]').click()
        assert page.locator("[data-widget]").nth(1).get_attribute("data-widget") == first_widget
        page.locator('[data-v4="layoutSave"]').click()
        assert page.evaluate("S.controlLayout.length") == 5
        page.locator('[data-page="lab"]').click()
        page.locator('[data-sim="case:14"]').click()
        page.locator('[data-sim="runCase"]').click()
        assert page.evaluate("scenarioExpectations[14]()")
        page.locator("#panic").click()
        assert page.evaluate("S.panic && !armed() && !consoleHeld.size")
        print("PASS: patchbay, layout reorder/save, cross-source sustain case, panic")
        page.set_viewport_size({"width": 390, "height": 844})
        for name in ("home", "touchlab", "mobilelab", "settings", "patchbay", "layouteditor"):
            page.locator(f'[data-page="{name}"]').click()
            assert page.locator("main h1").is_visible(), name
            assert page.evaluate("document.documentElement.scrollWidth <= innerWidth + 2"), f"horizontal page overflow: {name}"
        print("PASS: six mobile viewport navigation and overflow checks")
        assert not errors, errors
        browser.close()
finally:
    server.shutdown()
