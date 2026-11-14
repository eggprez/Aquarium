#!/bin/zsh
# Runs the Apple app's tests headlessly.
#
#   Tools/run-tests.sh <unit|iphone|ipad|mac|tv|watch|watchunit|all> [options] [-- extra xcodebuild args]
#
#   unit     AquariumTests (TestPlans/Unit) on the test iPhone, Apple TV and
#            (unless --no-mac) the Mac, then AquariumWatchTests (WatchUnit)
#            on the test watch.
#   iphone   AquariumUITests (TestPlans/iPhone) on the small, standard and Pro
#            Max test iPhones, and the Duo when its runtime is installed.
#   ipad     AquariumUITests (TestPlans/iPad) on the test iPad.
#   mac      AquariumUITests (TestPlans/Mac) on this Mac. Refuses while
#            Aquarium is running (the test build would quit it).
#   tv       AquariumUITests (TestPlans/TV) on the test Apple TV.
#   watch    AquariumWatchUITests (TestPlans/Watch) on the test watch,
#            paired with its own "Aquarium Test iPhone B" (or the pair named by
#            AQUARIUM_TEST_WATCH / AQUARIUM_TEST_WATCH_PHONE).
#   watchunit  AquariumWatchTests (WatchUnit) on the test watch only.
#   all      every one of the above, in that order.
#
# Options:
#   --only <Target/Class[/test]>   pass -only-testing (repeatable)
#   --device <name>                iphone: only this test device (small|standard|promax|duo)
#   --no-reset                     don't run the QA folder's suite-reset.py first
#   --no-mac                       unit: skip the Mac
#   --no-watch                     unit: skip the watch (run it alone with watchunit)
#   --results <dir>                where results go (default Aquarium/TestResults)
#
# Simulators: the script uses simulators of its own, named "Aquarium Test …",
# creating them the first time and booting them when needed. It never touches
# the other simulators (they hold real sign-ins), never shuts any down, and
# never kills the app: a run ends with `simctl terminate` at most.
#
# Results: <results>/<timestamp>-<suite>/<plan>-<device>.xcresult and .log,
# plus summary.txt. Open an .xcresult in Xcode, or:
#   xcrun xcresulttool get test-results summary --path <file>.xcresult
#
# Signing: simulator builds are ad-hoc signed (CODE_SIGN_IDENTITY=-); the Mac
# build is ad-hoc signed without sandbox or entitlements (see MAC_SIGN). Test mode keeps the app out of
# the keychain, so neither depends on a signed-in keychain.

set -u
HERE=${0:A:h}
PROJECT_DIR=${HERE:h}
cd "$PROJECT_DIR" || exit 1

suite=${1:-}
[[ -z $suite ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift

only=()
device_filter=""
do_reset=1
do_mac=1
do_watch_unit=1
results_root="$PROJECT_DIR/TestResults"
extra=()
while (( $# )); do
  case $1 in
    --only) only+=("-only-testing:$2"); shift 2;;
    --device) device_filter=$2; shift 2;;
    --no-reset) do_reset=0; shift;;
    --no-mac) do_mac=0; shift;;
    --no-watch) do_watch_unit=0; shift;;
    --results) results_root=$2; shift 2;;
    --) shift; extra=("$@"); break;;
    *) echo "unknown option $1"; exit 2;;
  esac
done

QA_DIR=${AQUARIUM_QA_DIR:-"$HOME/Library/Application Support/AquariumQA"}
stamp=$(date +%Y%m%d-%H%M%S)
out="$results_root/$stamp-$suite"
mkdir -p "$out"
summary="$out/summary.txt"
: > "$summary"
failures=0

IOS_RT=com.apple.CoreSimulator.SimRuntime.iOS-27-0
DUO_RT=com.apple.CoreSimulator.SimRuntime.iOS-27-1
TV_RT=com.apple.CoreSimulator.SimRuntime.tvOS-27-0
WATCH_RT=com.apple.CoreSimulator.SimRuntime.watchOS-27-0

# udid of the named simulator, created from (device type, runtime) if missing.
sim() {
  local name=$1 type=$2 runtime=$3 udid
  udid=$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name and d["isAvailable"]:
            print(d["udid"]); raise SystemExit
' "$name")
  if [[ -z $udid ]]; then
    udid=$(xcrun simctl create "$name" "com.apple.CoreSimulator.SimDeviceType.$type" "$runtime" 2>/dev/null) || return 1
    echo "created simulator $name ($udid)" >&2
  fi
  echo "$udid"
}

boot() {
  xcrun simctl bootstatus "$1" -b > /dev/null 2>&1
}

runtime_exists() {
  xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
ids = {r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable")}
raise SystemExit(0 if sys.argv[1] in ids else 1)' "$1"
}

reset_account() {
  (( do_reset )) || return 0
  if [[ -f "$QA_DIR/suite-reset.py" ]]; then
    (cd "$QA_DIR" && python3 -I suite-reset.py "suite-$1" > "$out/reset-$1.log" 2>&1) \
      && echo "reset suite-$1" || echo "warning: suite-reset.py suite-$1 failed (see $out/reset-$1.log)"
  fi
}

# run <scheme> <plan> <label> <destination> [signing args…]
run() {
  local scheme=$1 plan=$2 label=$3 dest=$4; shift 4
  local bundle="$out/$plan-$label.xcresult" log="$out/$plan-$label.log"
  echo "== $plan on $label"
  # TEST_RUNNER_ hands the QA folder to the UI-test runner (the Mac runner is
  # sandboxed, so its own home is not this one); no diagnostics after a failure,
  # which otherwise costs up to 10 minutes of simctl diagnose.
  TEST_RUNNER_AQUARIUM_QA_DIR="$QA_DIR" \
  xcodebuild test -scheme "$scheme" -testPlan "$plan" -destination "$dest" \
    -resultBundlePath "$bundle" -collect-test-diagnostics never \
    "${only[@]}" "$@" "${extra[@]}" > "$log" 2>&1
  local rc=$?
  local line
  line=$(grep -E "Executed [0-9]+ tests?|\*\* TEST (SUCCEEDED|FAILED) \*\*" "$log" | tail -2 | tr '\n' ' ')
  echo "$plan $label: exit $rc  $line" | tee -a "$summary"
  (( rc == 0 )) || failures=$((failures + 1))
}

SIM_SIGN=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
# The Mac: signed to run locally, without the sandbox or entitlements. The
# team's Mac provisioning profile doesn't list every Mac, and the app's
# iCloud and SharePlay entitlements need one. Unsandboxed, test mode's state
# lands in ~/Library/Preferences/scottai.FellyJin.uitest.plist and
# ~/Library/{Application Support,Caches}/AquariumUITest, away from the real
# app's container.
MAC_SIGN=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
          CODE_SIGN_ENTITLEMENTS= ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=NO)

do_unit() {
  local phone tv watch
  phone=$(sim "Aquarium Test iPhone 17" iPhone-17 $IOS_RT) && boot "$phone"
  run Aquarium Unit iPhone17 "id=$phone" "${SIM_SIGN[@]}"
  tv=$(sim "Aquarium Test Apple TV" Apple-TV-4K-3rd-generation-4K $TV_RT) && boot "$tv"
  run Aquarium Unit AppleTV "id=$tv" "${SIM_SIGN[@]}"
  if (( do_mac )); then
    if pgrep -f "Aquarium.app/Contents/MacOS/Aquarium" > /dev/null; then
      echo "Unit Mac: skipped, Aquarium is running on this Mac" | tee -a "$summary"
    else
      run Aquarium Unit Mac "platform=macOS" "${MAC_SIGN[@]}"
    fi
  fi
  (( do_watch_unit )) && do_watchunit
}

do_watchunit() {
  local watch
  watch=$(watch_pair) || { echo "WatchUnit: no test watch" | tee -a "$summary"; failures=$((failures + 1)); return; }
  run AquariumWatch WatchUnit Watch "id=$watch" "${SIM_SIGN[@]}"
}

do_iphone() {
  reset_account iphone
  local -a devices
  devices=("small:Aquarium Test iPhone SE:iPhone-SE-3rd-generation:$IOS_RT"
           "standard:Aquarium Test iPhone 17:iPhone-17:$IOS_RT"
           "promax:Aquarium Test iPhone 18 Pro Max:iPhone-18-Pro-Max:$IOS_RT")
  if runtime_exists $DUO_RT; then
    devices+=("duo:Aquarium Test iPhone Duo:iPhone-Duo:$DUO_RT")
  else
    echo "iPhone Duo: skipped, no iOS 27.1 (Duo) runtime" | tee -a "$summary"
  fi
  local entry key name type rt udid
  for entry in "${devices[@]}"; do
    IFS=: read key name type rt <<< "$entry"
    [[ -n $device_filter && $device_filter != $key ]] && continue
    udid=$(sim "$name" "$type" "$rt") || { echo "could not create $name" | tee -a "$summary"; continue; }
    boot "$udid"
    run Aquarium iPhone "$key" "id=$udid" "${SIM_SIGN[@]}"
    xcrun simctl terminate "$udid" scottai.FellyJin 2>/dev/null
  done
}

do_ipad() {
  reset_account ipad
  local udid
  udid=$(sim "Aquarium Test iPad Air 11" iPad-Air-11-inch-M4 $IOS_RT) && boot "$udid"
  run Aquarium iPad iPadAir11 "id=$udid" "${SIM_SIGN[@]}"
  xcrun simctl terminate "$udid" scottai.FellyJin 2>/dev/null
}

do_mac() {
  if pgrep -f "Aquarium.app/Contents/MacOS/Aquarium" > /dev/null; then
    echo "Mac: refused, Aquarium is running on this Mac (the test build would quit it). Quit it and run again." | tee -a "$summary"
    failures=$((failures + 1))
    return
  fi
  reset_account mac
  run Aquarium Mac Mac "platform=macOS" "${MAC_SIGN[@]}"
}

do_tv() {
  reset_account tv
  local udid
  udid=$(sim "Aquarium Test Apple TV" Apple-TV-4K-3rd-generation-4K $TV_RT) && boot "$udid"
  run Aquarium TV AppleTV "id=$udid" "${SIM_SIGN[@]}"
  xcrun simctl terminate "$udid" scottai.FellyJin 2>/dev/null
}

# The test watch, paired with its own test iPhone B; prints the watch's udid.
# AQUARIUM_TEST_WATCH and AQUARIUM_TEST_WATCH_PHONE name another pair (made
# the same way if missing), so a second run can have a watch of its own:
#   AQUARIUM_TEST_WATCH="Aquarium Test Watch B" AQUARIUM_TEST_WATCH_PHONE="Aquarium Test iPhone B" Tools/run-tests.sh watch
watch_pair() {
  local phone watch
  # Its own iPhone: unit tests on a phone paired with the test watch install
  # Aquarium there, and the phone's signed-out context then signs the watch out.
  phone=$(sim "${AQUARIUM_TEST_WATCH_PHONE:-Aquarium Test iPhone B}" iPhone-17 $IOS_RT) || return 1
  watch=$(sim "${AQUARIUM_TEST_WATCH:-Aquarium Test Watch B}" Apple-Watch-Series-12-46mm $WATCH_RT) || return 1
  if ! xcrun simctl list pairs | grep -q "$watch"; then
    xcrun simctl pair "$watch" "$phone" > /dev/null 2>&1 || echo "warning: could not pair the test watch" >&2
  fi
  boot "$watch"
  echo "$watch"
}

do_watch() {
  reset_account watch
  local watch
  watch=$(watch_pair) || { echo "Watch: no test watch" | tee -a "$summary"; failures=$((failures + 1)); return; }
  run AquariumWatch Watch Watch46 "id=$watch" "${SIM_SIGN[@]}"
  xcrun simctl terminate "$watch" scottai.FellyJin.watchkitapp 2>/dev/null
}

case $suite in
  unit) do_unit;;
  iphone) do_iphone;;
  ipad) do_ipad;;
  mac) do_mac;;
  tv) do_tv;;
  watch) do_watch;;
  watchunit) do_watchunit;;
  all) do_unit; do_iphone; do_ipad; do_tv; do_watch; do_mac;;
  *) echo "unknown suite $suite"; exit 2;;
esac

echo "results: $out"
cat "$summary"
exit $(( failures > 0 ))
