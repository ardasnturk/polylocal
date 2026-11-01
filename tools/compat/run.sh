#!/usr/bin/env bash
# Semi-automatic compatibility test: drives ⌘C+C and ⌘⇧C+C in real apps and reads back the result.
#
#   tools/compat/run.sh safari textarea
#   tools/compat/run.sh chrome contenteditable
#   tools/compat/run.sh pages
#   tools/compat/run.sh vscode
#
# Requires: Polylocal running (with a ready engine) and Accessibility access for the terminal.
# Never point this at messaging apps: a stray ↩ could send a real message.
# The clipboard is overwritten during the test and restored (text only) at the end.
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

APP="${1:?app: safari | chrome | pages | vscode | textedit}"
FIELD="${2:-textarea}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAGE="file://$ROOT/tools/compat/testpage.html?f=$FIELD"
TEXT="Können wir das Meeting auf morgen um drei Uhr verschieben?"
SCRATCH="${TMPDIR:-/tmp}/polylocal-compat.txt"
SAVED_CLIPBOARD="$(pbpaste 2>/dev/null || true)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"

frontmost() { osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true'; }

expected_bundle() {
    case "$APP" in
        safari) echo com.apple.Safari ;; chrome) echo com.google.Chrome ;; textedit) echo com.apple.TextEdit ;;
        pages) echo com.apple.iWork.Pages ;; vscode) echo com.microsoft.VSCode ;;
    esac
}

active_url() {
    case "$APP" in
        safari) osascript -e 'tell application "Safari" to get URL of current tab of front window' ;;
        chrome) osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' ;;
        *) echo "-" ;;
    esac
}

# Refuse to send a single key unless the target app (and, for browsers, the test page) is in front.
# Blind keystrokes once reloaded and closed tabs in the user's own windows; never again.
guard() {
    local front; front="$(frontmost)"
    if [ "$front" != "$(expected_bundle)" ]; then
        echo "ABORT: frontmost is $front, expected $(expected_bundle)"; printf '%s' "$SAVED_CLIPBOARD" | pbcopy; exit 2
    fi
    case "$APP" in
        safari|chrome)
            if [[ "$(active_url)" != *"tools/compat/testpage.html"* ]]; then
                echo "ABORT: active tab is not the test page"; printf '%s' "$SAVED_CLIPBOARD" | pbcopy; exit 2
            fi ;;
    esac
}

keys() { guard; osascript -e "tell application \"System Events\" to $1"; }
double() { # $1 = modifier list; one guard, then both presses in one call to stay inside the 0.4 s window
    guard
    osascript -e "tell application \"System Events\" to keystroke \"c\" using {$1}" -e 'delay 0.1' \
              -e "tell application \"System Events\" to keystroke \"c\" using {$1}"
}

wait_front() {  # up to 15 s for the target app to come to the front
    for _ in $(seq 1 30); do [ "$(frontmost)" = "$(expected_bundle)" ] && return; sleep 0.5; done
}

setup() {
    case "$APP" in
        safari|chrome)
            local name; [ "$APP" = safari ] && name=Safari || name="Google Chrome"
            open -a "$name" "$PAGE"
            # Wait until the browser is in front with the test page, up to 15 s.
            for _ in $(seq 1 30); do
                [ "$(frontmost)" = "$(expected_bundle)" ] && [[ "$(active_url)" == *"tools/compat/testpage.html"* ]] && break
                sleep 0.5
            done
            sleep 1 ;;
        textedit)
            osascript -e "tell application \"TextEdit\" to activate" \
                      -e "tell application \"TextEdit\" to make new document with properties {text:\"$TEXT\"}"
            wait_front; sleep 1; keys 'keystroke "a" using command down' ;;
        pages)
            osascript -e 'tell application "Pages" to activate' \
                      -e "tell application \"Pages\" to make new document" \
                      -e "tell application \"Pages\" to set body text of front document to \"$TEXT\""
            wait_front; sleep 2; keys 'keystroke "a" using command down' ;;
        vscode)
            printf '%s' "$TEXT" > "$SCRATCH"
            open -a "Visual Studio Code" "$SCRATCH"; wait_front; sleep 3
            keys 'keystroke "a" using command down' ;;
        *) echo "unknown app $APP"; exit 1 ;;
    esac
}

reselect() {
    case "$APP" in
        safari|chrome) keys 'keystroke "r" using command down'; sleep 2 ;;  # reload re-selects the field
        *) keys 'keystroke "a" using command down'; sleep 0.3 ;;
    esac
}

teardown() {
    case "$APP" in
        safari|chrome) keys 'keystroke "w" using command down' ;;
        textedit) osascript -e 'tell application "TextEdit" to close front document saving no' ;;
        pages) osascript -e 'tell application "Pages" to close front document saving no' ;;
        vscode) keys 'keystroke "s" using command down'; sleep 0.3; keys 'keystroke "w" using command down' ;;
    esac
}

setup
echo "== $APP / $FIELD"

double "command down"; sleep 3
keys 'key code 53'; sleep 0.5          # Esc closes the popup

reselect
if [ "${USE_REPLACE_SHORTCUT:-0}" = 1 ]; then
    double "command down, shift down"; sleep 3
    keys 'key code 36'; sleep 1.5      # ↩ = replace
else
    # Same replace path via the ⌘C+C popup (⌘↩); avoids ⌘⇧C, which clipboard managers often own.
    double "command down"; sleep 3
    keys 'key code 36 using command down'; sleep 1.5
fi

keys 'keystroke "a" using command down'; sleep 0.2
keys 'keystroke "c" using command down'; sleep 0.3
RESULT="$(pbpaste)"
teardown

if [ "$RESULT" = "$SAVED_CLIPBOARD" ]; then echo "field: could not read back"
elif [ "$RESULT" = "$TEXT" ]; then echo "field: unchanged"
else echo "field: $RESULT"; fi
/usr/bin/log show --style compact --predicate 'subsystem == "dev.polylocal.app"' --start "$SINCE" 2>/dev/null \
    | sed -n 's/.*\] //p' | grep -E '^(capture|replace)' || echo "(no log lines)"
printf '%s' "$SAVED_CLIPBOARD" | pbcopy
