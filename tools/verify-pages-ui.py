"""Offline UI-only smoke test. No native APIs; serves checked-out Pages HTML."""
import os
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
        engine = os.environ.get("UI_BROWSER", "chromium")
        browser = (p.chromium.launch(headless=True, executable_path=executable, args=["--no-sandbox"]) if executable else p.chromium.launch(headless=True)) if engine == "chromium" else p.webkit.launch(headless=True)
        context = browser.new_context(viewport={"width": 1440, "height": 960})
        context.route("**/*", lambda route: route.continue_() if route.request.url.startswith(f"http://127.0.0.1:{server.server_port}/") else route.abort())
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(url)
        page.wait_for_selector("[data-page=home]")
        assert page.locator("[data-page]").count() == 33
        for name in page.locator("[data-page]").evaluate_all("(xs) => xs.map(x => x.dataset.page)"):
            page.locator(f'[data-page="{name}"]').click()
            assert page.locator("main h1").count() == 1, name
        page.locator('[data-page="tests"]').click()
        page.locator('[data-v4="extendedChecks"]').click()
        assert page.evaluate("runChecks.length") == 81
        assert page.evaluate("runChecks.every(x => x.ok)")
        print("PASS: 33 desktop navigations and 81 browser-executed state checks")
        page.locator("#navSearch").fill("patchbay")
        assert page.locator("[data-page]:visible").count() == 1
        page.locator('[data-page="patchbay"]').click()
        page.locator("#navSearch").fill("")
        assert page.locator("[data-page]:visible").count() == 33
        page.locator('[data-page="settings"]').click()
        page.locator('[data-vfield="pref:language"]').select_option("Türkçe")
        assert "Ayarlar" in page.locator('[data-page="settings"]').inner_text()
        page.locator('[data-vfield="pref:language"]').select_option("Deutsch")
        assert "Einstellungen" in page.locator('[data-page="settings"]').inner_text()
        page.locator('[data-vfield="pref:language"]').select_option("English")
        print("PASS: search and sidebar language switches")
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
        third_widget = page.locator("[data-widget]").nth(2).get_attribute("data-widget")
        page.locator("[data-widget]").nth(1).locator(".draggrip").drag_to(page.locator("[data-widget]").nth(2))
        assert page.locator("[data-widget]").nth(2).get_attribute("data-widget") == first_widget
        assert page.locator("[data-widget]").nth(1).get_attribute("data-widget") == third_widget
        page.locator('[data-v4="layoutSave"]').click()
        assert page.evaluate("S.controlLayout.length") == 5
        print("PASS: actual drag handle reorder and save")
        page.locator('[data-page="stage"]').click()
        page.locator('[data-v4="stageView:Connections"]').click()
        page.locator('[data-sim="connect:tp"]').click()
        page.locator('[data-sim="arm:tp"]').click()
        page.locator('[data-v4="stageView:Controls"]').click()
        key = page.locator('[data-stagehold="tp:Contact"]')
        key.focus()
        page.keyboard.down("Space")
        assert page.evaluate("consoleHeld.size === 1")
        page.keyboard.up("Space")
        assert page.evaluate("consoleHeld.size === 0")
        page.get_by_role("button", name="Release all", exact=True).click()
        page.locator('[data-page="profiles"]').click()
        page.locator("#workspaceName").fill("Archive browser test")
        page.get_by_role("button", name="Save draft", exact=True).click()
        page.locator('[data-sim="localToggle"]').click()
        page.locator('[data-sim="localWrite"]').click()
        assert page.evaluate("JSON.parse(localStorage.getItem(archiveKey)).saved.length === 1")
        page.reload()
        page.locator('[data-page="profiles"]').click()
        page.locator('[data-sim="localRead"]').click()
        assert page.evaluate("S.saved.length === 1 && S.saved[0].layout.length === 5 && !armed()")
        page.locator('[data-sim="localRead"]').click()
        assert page.evaluate("S.saved.length === 1")
        print("PASS: stage key hold/release, explicit archive save and reload")
        page.locator('[data-sim="profile:7"]').click()
        page.locator('[data-page="mobilelab"]').click()
        page.locator('[data-vfield="mobileView"]').select_option("ta1")
        page.locator('[data-v4="mobileInsert"]').click()
        page.locator('[data-v4="mobileConnect"]').click()
        page.locator('[data-v4="mobileArm"]').click()
        page.locator('[data-v4="phoneEnable:ta1"]').click()
        key = page.locator('[data-momentary="ta1:Key 48"]')
        key.focus()
        page.keyboard.down("Space")
        assert page.evaluate("consoleHeld.size === 1 && phoneState.ta1.held.has('Key 48')")
        page.keyboard.up("Space")
        assert page.evaluate("consoleHeld.size === 0")
        key = page.locator('[data-momentary="ta1:Key 48"]')
        key.scroll_into_view_if_needed()
        box = key.bounding_box()
        page.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] * .85)
        page.mouse.down()
        assert page.evaluate("consoleHeld.size === 1")
        page.mouse.up()
        assert page.evaluate("consoleHeld.size === 0")
        print("PASS: mobile keyboard and pointer hold/release")
        page.locator('[data-page="lab"]').click()
        page.locator('[data-sim="case:14"]').click()
        page.locator('[data-sim="runCase"]').click()
        assert page.evaluate("scenarioExpectations[14]()")
        page.locator("#panic").click()
        assert page.evaluate("S.panic && !armed() && !consoleHeld.size")
        print("PASS: patchbay, layout reorder/save, cross-source sustain case, panic")
        page.set_viewport_size({"width": 390, "height": 844})
        for name in page.locator("[data-page]").evaluate_all("(xs) => xs.map(x => x.dataset.page)"):
            page.locator(f'[data-page="{name}"]').click()
            assert page.locator("main h1").is_visible(), name
            width = page.evaluate("document.documentElement.scrollWidth")
            if width > 392:
                offenders = page.evaluate("""() => [...document.querySelectorAll('main *')].map(e => ({tag:e.tagName, cls:typeof e.className==='string'?e.className:'svg',right:Math.round(e.getBoundingClientRect().right)})).filter(e=>e.right>innerWidth+2).slice(0,12)""")
                raise AssertionError(f"horizontal page overflow: {name}, width={width}, candidates={offenders}")
        print("PASS: all 33 mobile viewport navigation and overflow checks")
        assert not errors, errors
        browser.close()
finally:
    server.shutdown()
