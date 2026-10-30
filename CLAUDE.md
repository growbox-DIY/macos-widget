# Installing the GrowBox Mac widget – guide for Claude

The person you are helping may not be technical. The goal: `GrowBox
Widget.app` runs from `~/Applications`, the panel sits on the desktop and
the menu bar shows temperature and humidity from their GrowBox controller.

## How to talk

- Use the person's language. Short, plain sentences, one step at a time.
  No jargon; when a term is needed, explain it in a few words.
- Before each command, say in one sentence what it does. When macOS shows
  a dialog, tell them exactly what to click.
- Never ask for passwords in the chat. A password only goes into a macOS
  dialog or the Terminal prompt, typed by the person.

## Rules

- The controller runs a live grow. Only read from it (`GET /api/config`).
  Never call anything that changes settings, relays or the watering log.
- The API token lives only in `~/.config/growbox/widget.json`. Don't put
  it in the repo, don't commit, push or open issues.
- If a step fails twice, stop, explain it plainly and suggest asking in
  the GitHub issues of this repo.

## Steps

1. **Code.** If you are not inside a clone of this repo yet, run
   `git clone https://github.com/growbox-DIY/macos-widget.git` and work
   in that folder. If `git` is missing, do step 2 first.
2. **Developer tools.** `sw_vers -productVersion` must be 14 or newer.
   Check `swift --version`. If it is missing, run `xcode-select --install`,
   tell the person to click **Install** in the dialog and wait until it
   finishes (several minutes). No Apple account is needed.
3. **Controller.** Ask for the API token (the person who set up the
   controller has it: `API_TOKEN` in the firmware's `App/api_token.py`)
   and the address. If they don't know the address, try
   `http://esp32.local`. Test it:
   `curl -s -m 5 -H "Authorization: Bearer <token>" <url>/api/config`.
   JSON with `config` = OK; 401 = wrong token; no answer = the Mac is not
   on the same WiFi, or try the controller's IP from the router.
4. **Settings.** `~/.config/growbox/widget.json` is shared with the
   GrowBox Mac app. If it exists, show the person its `url` (never the
   token) and ask before changing it. Otherwise create it with mode 600:
   `{ "url": "http://...", "token": "..." }`
5. **Build and install.** `./build.sh install`. The first build takes a
   few minutes; then the widget opens. Its first start adds it to the
   login items, so it starts with the Mac.
6. **Local network.** macOS asks for access to the local network: tell
   them to click **Allow**. If they clicked Don't Allow: System Settings →
   Privacy & Security → Local Network → turn on GrowBox Widget.
7. **Check.** The panel and the menu bar show temperature and humidity.
   If not, go back to step 3 and check the local network permission.
8. **Wrap up.** Show them how to use it: drag the panel anywhere; click
   the leaf in the menu bar to hide or show the panel; right-click for the
   menu (Quit, Open at login). To update later, they open Claude in this
   folder and ask to update the widget: `git pull`, then
   `./build.sh install`.
