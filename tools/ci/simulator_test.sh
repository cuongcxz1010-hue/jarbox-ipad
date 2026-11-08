#!/bin/bash
# Run the built app in the iOS Simulator (iPad and iPhone) with test MIDlets,
# save screenshots and logs. Usage:
#   simulator_test.sh <JarBox.app> <jar directory> <output directory>
set -u

APP="$1"
JARS="$2"
OUT="$3"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
mkdir -p "$OUT"

pick_device() {     # newest available device whose name contains $1 → UDID
    xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)['devices']
best = None
for runtime, devices in data.items():
    if 'iOS' not in runtime: continue
    for d in devices:
        if '$1' in d['name']:
            key = runtime
            if best is None or key >= best[0]: best = (key, d['udid'], d['name'])
print(best[1] if best else '')
"
}

# run_scenario <udid> <label> <environment assignments...>  seconds taken from SECONDS_TO_RUN
run_scenario() {
    local udid="$1" label="$2"
    shift 2
    xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null
    echo "--- $label"
    env "$@" xcrun simctl launch "$udid" "$BUNDLE" >/dev/null 2>&1 || echo "launch failed"
    local waited=0
    for shot in $SHOTS; do
        sleep $((shot - waited))
        waited=$shot
        xcrun simctl io "$udid" screenshot "$OUT/${label}_${shot}s.png" >/dev/null 2>&1
    done
    local container
    container=$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)
    cp "$container/Documents/logs/jarbox-log.txt" "$OUT/${label}.log" 2>/dev/null
    grep -E "SELFTEST|\[TEST\] FAIL" "$OUT/${label}.log" | head -40
    xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null
}

test_device() {
    local family="$1" udid
    udid=$(pick_device "$family")
    if [ -z "$udid" ]; then echo "No $family simulator"; return; fi
    echo "=== $family: $udid"
    xcrun simctl boot "$udid" 2>/dev/null
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
    xcrun simctl install "$udid" "$APP" || { echo "install failed"; return; }

    local container
    container=$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)
    mkdir -p "$container/Documents/games"
    cp "$JARS"/*.jar "$container/Documents/games/"

    SHOTS="3 45"
    run_scenario "$udid" "${family}_selftest_portrait" \
        SIMCTL_CHILD_JARBOX_AUTORUN=selftest.jar SIMCTL_CHILD_JARBOX_ORIENTATION=portrait
    SHOTS="6"
    run_scenario "$udid" "${family}_home" SIMCTL_CHILD_X=1
    SHOTS="8 16"
    run_scenario "$udid" "${family}_demo_landscape" \
        SIMCTL_CHILD_JARBOX_AUTORUN=demo.jar SIMCTL_CHILD_JARBOX_ORIENTATION=landscape
    SHOTS="8 16"
    run_scenario "$udid" "${family}_demo_portrait" \
        SIMCTL_CHILD_JARBOX_AUTORUN=demo.jar SIMCTL_CHILD_JARBOX_ORIENTATION=portrait

    xcrun simctl shutdown "$udid" 2>/dev/null
}

test_device "iPad"
test_device "iPhone"
echo "Done. Results in $OUT"
