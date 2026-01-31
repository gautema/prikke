# Playwright Testing Guide

This guide explains how to use Playwright for visual testing and browser automation with the Runlater app.

## Prerequisites

Playwright is installed at:
```
/Users/gautema/.local/pipx/venvs/playwright/bin/python
```

## Running the Server

Start the Phoenix server before running Playwright scripts:
```bash
mix phx.server
```

## Authentication Methods

### Option 1: Password Login (Recommended for Automation)

If the user has a password set, use the password form:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 1400, 'height': 900})

    # Go to login page
    page.goto('http://localhost:4000/users/log-in')
    page.wait_for_load_state('networkidle')

    # Use password login (second form on the page)
    password_email_input = page.locator('input[type="email"]').nth(1)
    password_email_input.fill('user@example.com')

    password_input = page.locator('input[type="password"]')
    password_input.fill('YourPassword123!')

    # Click "Log in & remember"
    page.click('button:has-text("Log in & remember")')
    page.wait_for_load_state('networkidle')

    # Now navigate to authenticated pages
    page.goto('http://localhost:4000/dashboard')
    page.screenshot(path='/tmp/dashboard.png', full_page=True)

    browser.close()
```

### Option 2: Magic Link via Dev Mailbox

For users without passwords, use the dev mailbox to capture magic links:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 1400, 'height': 900})

    # Request magic link
    page.goto('http://localhost:4000/users/log-in')
    page.wait_for_load_state('networkidle')
    page.fill('input[type="email"]', 'user@example.com')
    page.click('button[type="submit"]')
    page.wait_for_load_state('networkidle')

    # Go to dev mailbox
    page.goto('http://localhost:4000/dev/mailbox')
    page.wait_for_load_state('networkidle')

    # Click on the email to view it
    page.click('a[href*="/dev/mailbox/"]:not([href*="/html"])')
    page.wait_for_load_state('networkidle')

    # Extract magic link href and navigate to it
    magic_link = page.locator('a[href*="/users/log-in/"]').first
    href = magic_link.get_attribute('href')
    page.goto(href)
    page.wait_for_load_state('networkidle')

    # Now logged in - navigate to authenticated pages
    page.goto('http://localhost:4000/dashboard')
    page.screenshot(path='/tmp/dashboard.png', full_page=True)

    browser.close()
```

## Setting a Password for a User

To enable password login for a user (useful for automation):

```bash
mix run -e '
user = Prikke.Repo.get_by!(Prikke.Accounts.User, email: "user@example.com")
{:ok, _user} = Prikke.Accounts.update_user_password(user, %{password: "TestPassword123!"})
IO.puts("Password set successfully!")
'
```

## Taking Screenshots

### Full Page Screenshot
```python
page.screenshot(path='/tmp/screenshot.png', full_page=True)
```

### Viewport Only
```python
page.screenshot(path='/tmp/screenshot.png')
```

### Custom Viewport Size
```python
page = browser.new_page(viewport={'width': 1400, 'height': 900})
```

## Waiting for Content

### Wait for Network Idle
```python
page.wait_for_load_state('networkidle')
```

### Wait for Specific Element
```python
page.wait_for_selector('#my-element')
```

### Wait for LiveView to Load
```python
page.wait_for_timeout(1000)  # Wait 1 second for LiveView
```

## Common Selectors

| Element | Selector |
|---------|----------|
| Email input (magic link) | `input[type="email"]` |
| Email input (password form) | `input[type="email"]:nth(1)` |
| Password input | `input[type="password"]` |
| Submit button | `button[type="submit"]` |
| Log in & remember | `button:has-text("Log in & remember")` |
| Magic link in email | `a[href*="/users/log-in/"]` |

## Example: Complete Superadmin Dashboard Screenshot

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 1400, 'height': 900})

    # Login
    page.goto('http://localhost:4000/users/log-in')
    page.wait_for_load_state('networkidle')

    page.locator('input[type="email"]').nth(1).fill('gaute.magnussen@gmail.com')
    page.locator('input[type="password"]').fill('TestPassword123!')
    page.click('button:has-text("Log in & remember")')
    page.wait_for_load_state('networkidle')

    # Navigate to superadmin
    page.goto('http://localhost:4000/superadmin')
    page.wait_for_load_state('networkidle')
    page.wait_for_timeout(1500)  # Wait for LiveView

    # Screenshot
    page.screenshot(path='/tmp/superadmin_dashboard.png', full_page=True)
    print("Screenshot saved!")

    browser.close()
```

## Running Scripts

```bash
# Run a Playwright script
/Users/gautema/.local/pipx/venvs/playwright/bin/python /path/to/script.py

# Or with server management
mix phx.server &
sleep 8 && /Users/gautema/.local/pipx/venvs/playwright/bin/python /path/to/script.py
pkill -f "mix phx.server"
```

## Debugging

### Print Page Content
```python
print(page.content()[:2000])
```

### List All Links
```python
links = page.locator('a').all()
for link in links[:10]:
    print(f"{link.inner_text()}: {link.get_attribute('href')}")
```

### Take Debug Screenshot
```python
page.screenshot(path='/tmp/debug.png')
```

## Key URLs

| Page | URL |
|------|-----|
| Login | `http://localhost:4000/users/log-in` |
| Register | `http://localhost:4000/users/register` |
| Dev Mailbox | `http://localhost:4000/dev/mailbox` |
| Dashboard | `http://localhost:4000/dashboard` |
| Superadmin | `http://localhost:4000/superadmin` |
| Landing Page (preview) | `http://localhost:4000/?preview=true` |
