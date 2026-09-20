#!/bin/bash
# Build Aetherfield for a physical iPad/iPhone, install it, and launch it.
# Works from Terminal or over ssh: no sudo, no GUI. Every precondition that has
# bitten this project is checked up front, with the fix in the error message.
#
#   ./deploy.sh                 build, install, launch
#   ./deploy.sh --skip-build    reinstall whatever was last built
#   ./deploy.sh --no-launch     install but don't start the app
#   DEVICE=<name|UDID|CoreDevice ID> ./deploy.sh    pick a device when several are paired
#
# Do not "fix" the build by using `xcodebuild ... install`: it does not reliably
# push to a physical device. `devicectl device install app` is the reliable step.

set -euo pipefail
cd "$(dirname "$0")"

PROJECT=AirGradientMonitor.xcodeproj
SCHEME=AirGradientMonitor
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-180}

build=1; launch=1
for arg in "$@"; do
  case $arg in
    --skip-build) build=0 ;;
    --no-launch)  launch=0 ;;
    -h|--help)    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# Run a command, killing it if it goes silent for too long. devicectl can hang
# with no output when the device is locked or a trust prompt is pending.
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# --- Preflight ---------------------------------------------------------------

step "Preflight"

# Developer Mode on the Mac. Off, devicectl install fails with the unhelpful
# "Authorization is required to install the packages".
if ! /usr/sbin/DevToolsSecurity -status 2>&1 | grep -qi 'enabled'; then
  die "macOS Developer Mode is off. Run once:  sudo /usr/sbin/DevToolsSecurity -enable"
fi
echo "Developer Mode: on"

# Signing. Actually sign a scratch binary with the identity rather than just
# listing it: a listed identity whose private key this session may not use is
# exactly what fails later, deep in the build, as errSecInternalComponent.
identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
[ -n "$identity" ] || die "no valid 'Apple Development' signing identity in the keychain."
probe=$(mktemp -t deploy-probe)
trap 'rm -f "$probe"' EXIT
cp /usr/bin/true "$probe"
if ! err=$(codesign --force --sign "$identity" "$probe" 2>&1); then
  cat >&2 <<EOF
$err

FAILED: this session cannot use the signing key (session type: $(launchctl managername)).
Over ssh the login keychain is usually locked. Try, in this shell:
    security unlock-keychain ~/Library/Keychains/login.keychain-db
If it still fails, grant codesign access to the key once (asks for your login password):
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
EOF
  exit 1
fi
echo "Signing identity: $identity (usable from this session)"

# The device: one physical, paired device, unless DEVICE says otherwise.
json=$(mktemp -t deploy-devices)
trap 'rm -f "$probe" "$json"' EXIT
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || die "devicectl could not list devices."
device_line=$(python3 - "$json" "${DEVICE:-}" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
devs = json.load(open(path))["result"]["devices"]
def props(d):
    hw = d.get("hardwareProperties", {}); dp = d.get("deviceProperties", {}); cp = d.get("connectionProperties", {})
    return hw, dp, cp
found = []
for d in devs:
    hw, dp, cp = props(d)
    if hw.get("reality") != "physical" or cp.get("pairingState") != "paired":
        continue
    names = {d.get("identifier"), hw.get("udid"), dp.get("name")}
    if want and want not in names:
        continue
    found.append((d["identifier"], dp.get("name", "?"), dp.get("developerModeStatus", "?")))
if not found:
    print("ERR no paired physical device" + (" matching '%s'" % want if want else "") + ".")
elif len(found) > 1:
    print("ERR several paired devices (%s); set DEVICE=<name>." % ", ".join(n for _, n, _ in found))
else:
    print("OK\t%s\t%s\t%s" % found[0])
PY
)
case $device_line in ERR*) die "${device_line#ERR }" ;; esac
IFS=$'\t' read -r _ device_id device_name device_devmode <<<"$device_line"
[ "$device_devmode" = "enabled" ] || die "Developer Mode is off on '$device_name'. Settings > Privacy & Security > Developer Mode."
echo "Device: $device_name ($device_id)"

# --- Build -------------------------------------------------------------------

if [ "$build" = 1 ]; then
  step "Build"
  # -allowProvisioningUpdates renews the profile; it does NOT register a brand-new
  # device (fails "isn't registered in your developer account"). For that, open
  # the project in Xcode once and hit Run.
  if ! xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" -destination generic/platform=iOS \
      -allowProvisioningUpdates build 2>&1 | tail -n 25; then
    die "xcodebuild failed (last output above)."
  fi
fi

settings=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination generic/platform=iOS -showBuildSettings 2>/dev/null)
setting() { awk -v k="$1" '$1 == k && $2 == "=" {sub(/^[^=]*= /, ""); print; exit}' <<<"$settings"; }
app="$(setting TARGET_BUILD_DIR)/$(setting FULL_PRODUCT_NAME)"
bundle_id=$(setting PRODUCT_BUNDLE_IDENTIFIER)
[ -d "$app" ] || die "no built app at $app. Run without --skip-build."

# --- Install and launch ------------------------------------------------------

step "Install $bundle_id"
with_timeout "$INSTALL_TIMEOUT" xcrun devicectl device install app --device "$device_id" "$app" \
  || die "install failed or gave no answer in ${INSTALL_TIMEOUT}s. Is the device unlocked and awake?"

if [ "$launch" = 1 ]; then
  step "Launch"
  with_timeout 60 xcrun devicectl device process launch --device "$device_id" --terminate-existing "$bundle_id" \
    || die "installed, but launch failed. The device is probably locked; unlock it and run again with --skip-build."
fi

printf '\nDone: %s on %s.\n' "$bundle_id" "$device_name"
