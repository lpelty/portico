#!/usr/bin/env bash
# What bin/install needs before it starts, checked in plain words (the doctor checks the same
# things once the gateway is installed). One line per check; exit 1 when any fails.
#   app/Packaging/prereqs.sh <repo>
set -uo pipefail

repo="${1:?usage: prereqs.sh <repo>}"
failed=0
ok() { echo "ok   $1: $2"; }
fail() { echo "FAIL $1: $2"; failed=1; }

# Command Line Tools: Xcode is not needed, the CLT alone build the app. Checked before swift,
# because without them /usr/bin/swift opens the installer dialog instead of answering.
clt_ok=0
if dev="$(xcode-select -p 2>/dev/null)" && [ -n "$dev" ] && [ -d "$dev" ]; then
  clt_ok=1
  clt_version="$(/usr/sbin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | awk '/^version:/{print $2}')"
  if [ -n "$clt_version" ]; then
    ok "command line tools" "$clt_version (active developer dir: $dev)"
  else
    ok "command line tools" "developer dir $dev (the Command Line Tools package is not installed; Xcode's tools are used)"
  fi
else
  fail "command line tools" "not installed. Run: xcode-select --install (Xcode is not needed)"
fi

if [ "$clt_ok" = 1 ]; then
  if ! command -v swift >/dev/null 2>&1; then
    fail "swift" "swift is not on PATH; reinstall the Command Line Tools: xcode-select --install"
  elif version="$(swift --version 2>&1)"; then
    ok "swift" "$(printf '%s\n' "$version" | grep -m1 -o 'Swift version [0-9.]*' || printf '%s\n' "$version" | head -n 1)"
  else
    fail "swift" "swift does not run ($(printf '%s\n' "$version" | head -n 1)); reinstall the Command Line Tools: xcode-select --install"
  fi
else
  fail "swift" "not checked: it comes with the Command Line Tools"
fi

if command -v uv >/dev/null 2>&1; then
  ok "uv" "$(uv --version 2>/dev/null | head -n 1)"
else
  fail "uv" "uv is not on PATH. Install it: https://docs.astral.sh/uv/getting-started/installation/ (or: brew install uv)"
fi

# Python: what gateway/pyproject.toml requires. uv provides a managed Python, so an older
# system python3 is not a failure.
want="$(sed -n 's/^requires-python *= *"[^0-9]*\([0-9][0-9.]*\)".*/\1/p' "$repo/gateway/pyproject.toml" | head -n 1)"
want="${want:-3.13}"
system_note=""
if command -v python3 >/dev/null 2>&1; then
  sys_version="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)"
  if [ -n "$sys_version" ]; then
    if python3 -c "import sys; sys.exit(0 if sys.version_info[:2] >= tuple(int(n) for n in '$want'.split('.')[:2]) else 1)" 2>/dev/null; then
      system_note=""
    else
      system_note="; the system python3 is $sys_version, which the gateway does not use"
    fi
  fi
fi
if command -v uv >/dev/null 2>&1; then
  if found="$(cd "$repo/gateway" && uv python find ">=$want" 2>/dev/null)" && [ -n "$found" ]; then
    found_version="$("$found" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)"
    ok "python" "${found_version:-$want or newer} ($found)$system_note"
  else
    ok "python" "no Python $want or newer yet; uv downloads a managed one during the install$system_note"
  fi
else
  fail "python" "not checked: the gateway's Python $want comes from uv"
fi

exit "$failed"
