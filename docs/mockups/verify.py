"""Verify the offline review prototype and regenerate its screenshots."""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parent
URL = (ROOT / 'index.html').as_uri()
checks = []
errors = []
network = []

def check(name, condition):
    assert condition, name
    checks.append(name)

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width': 1360, 'height': 1030}, device_scale_factor=1)
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.route('http://**/*', lambda route: (network.append(route.request.url), route.abort()))
    page.route('https://**/*', lambda route: (network.append(route.request.url), route.abort()))
    page.goto(URL)
    page.screenshot(path=str(ROOT / 'px2-dark.png'), full_page=True)
    check('Initial Apply disabled', page.locator('#apply').is_disabled())
    page.locator('#dpi').fill('123')
    check('Invalid DPI blocked', page.locator('#apply').is_disabled() and page.locator('#dpi-error').is_visible())
    page.locator('#dpi').fill('2400')
    check('Valid staged DPI enables Apply', page.locator('#apply').is_enabled())
    page.locator('#apply').click()
    check('Apply clears pending changes', page.locator('#apply').is_disabled() and page.locator('#dpi').input_value() == '2400')
    page.locator('#dpi').fill('3200')
    page.locator('[data-profile="2"]').click()
    check('Dirty navigation prompts', page.locator('#dialog').is_visible())
    page.locator('#dialog button[value="cancel"]').click()
    check('Cancel retains draft and profile', page.locator('#dpi').input_value() == '3200' and 'Profile 1' in page.locator('#page-title').inner_text())
    page.locator('[data-profile="2"]').click()
    page.locator('#dialog button[value="confirm"]').click()
    page.locator('[data-page="hits"]').click()
    check('Inactive profile HITS disabled', page.locator('#actuation').is_disabled())
    page.locator('#activate').click()
    check('Activation enables HITS', page.locator('#actuation').is_enabled())
    page.locator('#actuation').fill('5')
    page.locator('#apply').click()
    page.locator('[data-button="right"]').click()
    check('Left HITS does not change right', page.locator('#actuation').input_value() == '3')
    page.locator('[data-button="left"]').click()
    check('Left HITS edit retained', page.locator('#actuation').input_value() == '5')
    page.locator('#scenario').select_option('factory')
    check('Factory profile writes disabled', page.locator('#dpi').is_disabled())
    page.locator('#initialize').click()
    check('Initialization requires confirmation', page.locator('#dialog').is_visible())
    page.locator('#dialog button[value="confirm"]').click()
    expect(page.locator('#dpi')).to_be_enabled()
    check('Initialization enables editor', page.locator('#dpi').is_enabled())
    page.locator('#scenario').select_option('offline')
    check('Disconnected editor disabled', page.locator('#dpi').is_disabled())
    page.locator('[data-page="restoration"]').click()
    check('Offline restoration remains available', 'Waiting for device' in page.locator('#content').inner_text())
    page.locator('#scenario').select_option('partial')
    page.locator('#dpi').fill('2400')
    page.locator('#rate').select_option('2000')
    page.locator('#apply').click()
    check('Partial failure retains one pending change', page.locator('#dirty-title').inner_text() == '1 pending change')
    page.locator('#discard').click()
    check('Discard after partial failure retains successful DPI', page.locator('#dpi').input_value() == '2400' and page.locator('#rate').input_value() == '1000')
    screenshots = [('px2-light.png','?theme=light'),('px2-hits.png','?page=hits'),('px2-factory.png','?state=factory'),('px2-disconnected.png','?state=offline')]
    for name, query in screenshots:
        page.goto(URL+query)
        page.screenshot(path=str(ROOT/name), full_page=True)
    for width in [390,620,900,1360]:
        page.set_viewport_size({'width':width,'height':1030})
        for theme in ['dark','light']:
            for section in ['sensitivity','hits','restoration','diagnostics']:
                page.goto(URL+f'?theme={theme}&page={section}')
                check(f'No horizontal overflow: {width}px {theme} {section}', page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
    page.set_viewport_size({'width':390,'height':1030})
    page.goto(URL)
    page.screenshot(path=str(ROOT/'px2-narrow.png'), full_page=True)
    page.locator('#mobile-profile').select_option('2')
    check('Narrow profile selector works', 'Profile 2' in page.locator('#page-title').inner_text())
    page.keyboard.press('Tab')
    check('Keyboard focus visible', page.evaluate('document.activeElement.matches(":focus-visible")'))
    check('No JavaScript errors', not errors)
    check('No external network requests', not network)
    report = {'browser':browser.version,'checks':checks,'screenshots':['px2-dark.png']+[n for n,_ in screenshots]+['px2-narrow.png'],'javascript_errors':errors,'network_requests':network,'scope':'Offline HTML review artifact only; no GTK or device validation.'}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'{len(checks)} checks passed; {len(report["screenshots"])} screenshots generated.')
    browser.close()
