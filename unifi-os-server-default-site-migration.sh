bash <<'UOS_EOF'
# =============================================================================
# UniFi OS Server: make an imported site the default site
#
# Paste this whole block into an SSH session on the Linux server running
# UniFi OS Server. Your site must already be imported (site switcher >
# Import Site).
#
# The script:
#   1. Finds the UniFi OS Server service, its service account, the container,
#      the Mongo client, and the UniFi Network database.
#   2. Lists your sites. You pick the one that should become the default.
#   3. Moves the default flags from the old Default site to your site and
#      restarts the service.
#   4. Deletes the old Default site.
#   5. Renames your site's internal name to "default", turns off Multi-Site
#      Management if your site is the only one left, and restarts again.
#   6. Asks you to confirm the result in the UI.
#
# NOT SUPPORTED BY UBIQUITI. Direct database edits may break with updates.
# Use at your own risk.
#
# Method: Ubiquiti Community Wiki, "Changing the Default Site in UniFi"
# https://ubntwiki.com/guides/changing_the_default_site_in_unifi
# =============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Output and input
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLD=$'\033[1m'; C_OFF=$'\033[0m'; C_CLR=$'\r\033[K'
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""; C_CLR=$'\n'
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; exit 1; }
step() { STEP="$*"; printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }

# The script itself arrives on stdin (the pasted block), so every answer is
# read from the keyboard (/dev/tty), never from stdin.
ask() {
  local answer=""
  printf '%s' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || fail "Could not read from the keyboard."
  ANSWER="$answer"
}

ask_yn() {
  while true; do
    ask "$1 (y/n): "
    case "$ANSWER" in
      y|Y|yes|Yes|YES) return 0 ;;
      n|N|no|No|NO)    return 1 ;;
    esac
    say "Please answer y or n."
  done
}

# Counts non-empty lines.
count_lines() { printf '%s' "$1" | grep -c . || true; }

STEP="start"
trap 'printf "\n"; warn "Stopped by user during: $STEP"; exit 130' INT

# ----------------------------------------------------------------------------
# Container and Mongo access
# ----------------------------------------------------------------------------

# Rootless podman runs as the service account. sudo -u fails from a directory
# that account cannot read ("cannot chdir ... Permission denied"), so always
# run from /tmp.
as_svc() {
  (cd /tmp && sudo -u "$SVC_USER" XDG_RUNTIME_DIR="/run/user/$SVC_UID" podman "$@" </dev/null)
}

in_container() { as_svc exec "$CONTAINER" "$@"; }

mongo_js() {
  in_container "$MONGO_CLIENT" --quiet --port "$MONGO_PORT" "$MONGO_DB" --eval "$1"
}

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------

check_basics() {
  cd /tmp || fail "Cannot change to /tmp."
  local cmd
  for cmd in sudo systemctl ps getent id awk grep; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
  done
  # Throw away anything left over from the paste (such as a trailing empty
  # line), so sudo does not read it as the password.
  while IFS= read -r -t 0.3 _ </dev/tty; do :; done
  say "Checking sudo access. You may be asked for your password."
  sudo -v </dev/tty || fail "sudo access is required."
  ok "sudo access confirmed."
}

service_running() {
  local out
  out=$(systemctl status "$UNIT" --no-pager 2>/dev/null </dev/null)
  [[ $out == *"active (running)"* ]]
}

find_service_unit() {
  local units files
  units=$(systemctl list-unit-files 'uosserver*.service' --no-legend 2>/dev/null </dev/null \
    | awk '{print $1}' | grep -v -- '-updater' || true)
  if [[ $(count_lines "$units") -eq 1 ]]; then
    UNIT="${units%.service}"
  elif printf '%s\n' "$units" | grep -qx 'uosserver.service'; then
    UNIT="uosserver"
  else
    # Fallback: any unit that starts the UniFi OS Server binary.
    files=$(grep -l '/var/lib/uosserver/bin/uosserver-service' \
      /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service 2>/dev/null \
      | grep -v -- '-updater' | head -n1 || true)
    [[ -n $files ]] || fail "No UniFi OS Server systemd unit found. Is UniFi OS Server installed on this machine?"
    UNIT=$(basename "$files" .service)
  fi
  service_running || fail "$UNIT is not active (running). Check: systemctl status $UNIT --no-pager"
  ok "Service unit: $UNIT (active, running)"
}

find_service_user() {
  local owners owner candidates
  owners=$(ps -eo user,pid,comm </dev/null | grep -Ei 'podman|conmon|catatonit' \
    | awk '{print $1}' | grep -vx root | sort -u || true)
  candidates=$(getent passwd </dev/null | grep -Ei 'unifi|uos' | cut -d: -f1 || true)
  SVC_USER=""

  if [[ $(count_lines "$owners") -eq 1 ]]; then
    owner="${owners%+}"
    if [[ $owner =~ ^[0-9]+$ ]]; then
      # ps printed a numeric UID instead of a name.
      SVC_USER=$(getent passwd "$owner" </dev/null | cut -d: -f1 || true)
    else
      # ps may truncate long names, e.g. "uosserv+".
      local match
      match=$(printf '%s\n' "$candidates" | awk -v o="$owner" 'index($0, o) == 1')
      [[ $(count_lines "$match") -eq 1 ]] && SVC_USER="$match"
    fi
  fi
  if [[ -z $SVC_USER ]] && printf '%s\n' "$candidates" | grep -qx 'uosserver'; then
    SVC_USER="uosserver"
  fi
  [[ -n $SVC_USER ]] || fail "Could not find the account that runs the UniFi OS Server containers."

  SVC_UID=$(id -u "$SVC_USER" 2>/dev/null) || fail "Could not get the UID of $SVC_USER."
  ls -d "/run/user/$SVC_UID" >/dev/null 2>&1 || fail "Runtime directory /run/user/$SVC_UID does not exist."
  ok "Service account: $SVC_USER (UID $SVC_UID)"
}

find_container() {
  local rows names pick
  rows=$(as_svc ps --format "{{.Names}}\t{{.Image}}" 2>&1) || { say "$rows"; fail "podman ps failed as $SVC_USER."; }
  names=$(printf '%s\n' "$rows" | awk 'NF {print $1}')
  [[ $(count_lines "$names") -gt 0 ]] || fail "No running containers found for $SVC_USER."

  pick=$(printf '%s\n' "$rows" | awk 'NF && $2 ~ /uosserver/ {print $1}')
  if [[ $(count_lines "$pick") -ne 1 ]]; then
    if printf '%s\n' "$names" | grep -qx 'uosserver'; then
      pick="uosserver"
    elif [[ $(count_lines "$names") -eq 1 ]]; then
      pick="$names"
    else
      say "$rows"
      fail "Could not tell which container is UniFi OS Server."
    fi
  fi
  CONTAINER="$pick"
  CONTAINER_IMAGE=$(printf '%s\n' "$rows" | awk -v c="$CONTAINER" '$1 == c {print $2; exit}')
  ok "Container: $CONTAINER (${CONTAINER_IMAGE:-image unknown})"
}

find_mongo() {
  local found props value
  found=$(in_container which mongosh mongo 2>/dev/null || true)
  MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongo$' | head -n1 || true)
  [[ -n $MONGO_CLIENT ]] || MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongosh$' | head -n1 || true)
  [[ -n $MONGO_CLIENT ]] || fail "No mongo or mongosh client found inside $CONTAINER."

  # The UniFi Network app's own settings name its database and port.
  MONGO_PORT="27117"; MONGO_DB="ace"
  props=$(in_container cat /usr/lib/unifi/data/system.properties 2>/dev/null || true)
  if [[ -n $props ]]; then
    value=$(printf '%s\n' "$props" | sed -n 's/^[[:space:]]*unifi\.db\.port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | tail -n1)
    [[ -n $value ]] && MONGO_PORT="$value"
    value=$(printf '%s\n' "$props" | sed -n 's/^[[:space:]]*unifi\.db\.name[[:space:]]*=[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | tail -n1)
    [[ -n $value ]] && MONGO_DB="$value"
    if printf '%s\n' "$props" | grep -Eq '^[[:space:]]*db\.mongo\.local[[:space:]]*=[[:space:]]*false'; then
      fail "This install uses an external MongoDB (db.mongo.local=false). Not supported by this script."
    fi
  fi

  local out
  out=$(mongo_js 'print("UOSDB " + db.getName())' 2>&1)
  [[ $out == *"UOSDB $MONGO_DB"* ]] || { say "$out"; fail "Could not open database $MONGO_DB on port $MONGO_PORT."; }
  ok "Mongo: $MONGO_CLIENT, port $MONGO_PORT, database $MONGO_DB"
}

# ----------------------------------------------------------------------------
# Sites
# ----------------------------------------------------------------------------

# One UOSSITE line per document in the site collection. Empty values print as
# "-" so tab-separated parsing keeps its columns. desc is last (free text).
JS_HELPERS='var h = function (o) { return (typeof o.toHexString === "function") ? o.toHexString() : o.str; };
var v = function (x) { return (x === undefined || x === null || x === "") ? "-" : String(x); };'

JS_SITES="$JS_HELPERS"'
db.site.find().forEach(function (d) {
  print(["UOSSITE", h(d._id), v(d.name), v(d.attr_hidden_id), v(d.attr_no_delete), v(d.desc)].join("\t"));
});
print("UOSEND");'

# Returns 1 if the query did not complete (for example, during a restart).
load_sites() {
  local out id name hid nodel desc
  out=$(mongo_js "$JS_SITES" 2>/dev/null) || return 1
  [[ $out == *UOSEND* ]] || return 1
  S_ID=(); S_NAME=(); S_HID=(); S_NODEL=(); S_DESC=()
  while IFS=$'\t' read -r _ id name hid nodel desc; do
    [[ -n $id ]] || continue
    S_ID+=("$id"); S_NAME+=("$name"); S_HID+=("$hid"); S_NODEL+=("$nodel"); S_DESC+=("$desc")
  done < <(printf '%s\n' "$out" | grep '^UOSSITE')
  return 0
}

is_super()   { [[ ${S_NAME[$1]} == "super" || ${S_HID[$1]} == "super" ]]; }
is_default() { [[ ${S_HID[$1]} == "default" ]]; }

index_of_id() {
  local i
  for i in "${!S_ID[@]}"; do
    [[ ${S_ID[i]} == "$1" ]] && { echo "$i"; return 0; }
  done
  return 1
}

site_label() {
  local d="${S_DESC[$1]}"
  [[ $d == "-" ]] && d="(no description)"
  printf '%s  (name: %s)' "$d" "${S_NAME[$1]}"
}

# Sets TARGET_ID. Lists every site except super. The current Default is shown
# dimmed and cannot be chosen.
choose_site() {
  local i n=0 choices=()
  say "Sites found in database $MONGO_DB:"
  say ""
  for i in "${!S_ID[@]}"; do
    is_super "$i" && continue
    if is_default "$i"; then
      printf '   %s-)  %s   <- current Default, not selectable%s\n' "$C_DIM" "$(site_label "$i")" "$C_OFF"
    else
      n=$((n + 1)); choices+=("$i")
      printf '  %2d)  %s\n' "$n" "$(site_label "$i")"
    fi
  done
  say ""
  while true; do
    ask "Which site should become the default? Enter a number (1-$n): "
    if [[ $ANSWER =~ ^[0-9]+$ ]] && (( ANSWER >= 1 && ANSWER <= n )); then
      TARGET_ID="${S_ID[${choices[$((ANSWER - 1))]}]}"
      local t; t=$(index_of_id "$TARGET_ID")
      if ask_yn "Make $(site_label "$t") the default site?"; then
        return 0
      fi
    else
      say "Enter a number from 1 to $n."
    fi
  done
}

selectable_count() {
  local i n=0
  for i in "${!S_ID[@]}"; do
    is_super "$i" || is_default "$i" || n=$((n + 1))
  done
  echo "$n"
}

# Used when only Default and super exist but the user says the site was
# imported. Waits for a late import, then looks in every other database for a
# site collection. No source shows an import landing outside the Network
# database; this is a best-effort search.
search_for_site() {
  local i
  say "Checking again for up to 60 seconds in case the import is still finishing..."
  for (( i = 60; i > 0; i-- )); do
    printf '%s  Rechecking database %s... %ds' "$C_CLR" "$MONGO_DB" "$i"
    if load_sites && [[ $(selectable_count) -gt 0 ]]; then
      printf '%s' "$C_CLR"; ok "Found your site in $MONGO_DB."
      return 0
    fi
    sleep 1
  done
  printf '%s' "$C_CLR"

  say "Searching the other databases on this MongoDB instance..."
  local out found dbs
  out=$(mongo_js "$JS_HELPERS"'
db.adminCommand({ listDatabases: 1 }).databases.forEach(function (x) {
  if (["admin", "local", "config"].indexOf(x.name) >= 0) return;
  var d = db.getSiblingDB(x.name);
  if (d.getCollectionNames().indexOf("site") < 0) return;
  d.site.find().forEach(function (s) {
    if (s.name === "super" || s.attr_hidden_id === "super" || s.attr_hidden_id === "default") return;
    print(["UOSFOUND", x.name, h(s._id), v(s.name), v(s.desc)].join("\t"));
  });
});
print("UOSEND");' 2>&1)
  found=$(printf '%s\n' "$out" | grep '^UOSFOUND' || true)
  if [[ -z $found ]]; then
    say ""
    warn "No imported site was found in any database."
    say "In the UniFi Network UI, open the site switcher and check that your site is listed."
    say "If it is not, import it again (site switcher > Import Site), then rerun this script."
    exit 1
  fi

  say "Sites found outside $MONGO_DB:"
  printf '%s\n' "$found" | awk -F'\t' '{printf "  database %s: %s (name: %s)\n", $2, $5, $4}'
  dbs=$(printf '%s\n' "$found" | cut -f2 | sort -u)
  if [[ $(count_lines "$dbs") -eq 1 ]] && ask_yn "Use database $dbs instead of $MONGO_DB?"; then
    MONGO_DB="$dbs"
    load_sites || fail "Could not read sites from $MONGO_DB."
    return 0
  fi
  say "Stopping. Check which database your UniFi Network application uses, then rerun this script."
  exit 1
}

# ----------------------------------------------------------------------------
# Writes and restarts
# ----------------------------------------------------------------------------

# $1: an updateOne call. Mongo reports how many documents matched and how many
# changed. Both must be 1.
update_one() {
  local out re='UOSRESULT ([0-9]+) ([0-9]+)'
  out=$(mongo_js "var r = $1; print('UOSRESULT ' + r.matchedCount + ' ' + r.modifiedCount);" 2>&1)
  if [[ $out =~ $re ]] && [[ ${BASH_REMATCH[1]} == 1 && ${BASH_REMATCH[2]} == 1 ]]; then
    return 0
  fi
  say "$out"
  return 1
}

restart_service() {
  say "Restarting $UNIT. This restarts every application on this server."
  sudo systemctl restart "$UNIT" </dev/null || fail "systemctl restart $UNIT failed."
  local start=$SECONDS limit=600 elapsed
  while true; do
    elapsed=$((SECONDS - start))
    if service_running && load_sites; then
      printf '%s' "$C_CLR"
      ok "$UNIT is running and the database answers (${elapsed}s)."
      return 0
    fi
    (( elapsed >= limit )) && { printf '\n'; fail "$UNIT did not come back within ${limit}s. Check: systemctl status $UNIT --no-pager"; }
    printf '%s  Waiting for %s and the database... %ds' "$C_CLR" "$UNIT" "$elapsed"
    sleep 2
  done
}

show_site() {
  local i
  i=$(index_of_id "$1") || return 0
  say "  _id: ${S_ID[i]}  name: ${S_NAME[i]}  desc: ${S_DESC[i]}  attr_hidden_id: ${S_HID[i]}  attr_no_delete: ${S_NODEL[i]}"
}

# Checks every second. 5-minute countdown, then asks the user.
# ----------------------------------------------------------------------------
# Final check
# ----------------------------------------------------------------------------

diagnose() {
  local i others=() problems=0
  say ""
  say "Checking what the database shows:"
  if service_running; then ok "$UNIT is active (running)."; else warn "$UNIT is not active (running)."; problems=1; fi
  if ! load_sites; then
    warn "The database did not answer. The service may still be starting; wait a minute and check again."
    return
  fi
  for i in "${!S_ID[@]}"; do is_super "$i" || others+=("$i"); done

  if [[ ${#others[@]} -eq 1 ]]; then
    ok "Exactly one site besides the hidden system site."
  else
    warn "${#others[@]} sites besides the hidden system site:"
    for i in "${others[@]}"; do say "  $(site_label "$i")"; done
    problems=1
  fi

  if i=$(index_of_id "$TARGET_ID"); then
    [[ ${S_NAME[i]} == "default" ]]  && ok "Your site's internal name is default."        || { warn "Your site's internal name is ${S_NAME[i]}, not default."; problems=1; }
    [[ ${S_HID[i]} == "default" ]]   && ok "Your site holds attr_hidden_id: default."      || { warn "Your site is missing attr_hidden_id: default."; problems=1; }
    [[ ${S_NODEL[i]} == "true" ]]    && ok "Your site holds attr_no_delete: true."         || { warn "Your site is missing attr_no_delete: true."; problems=1; }
  else
    warn "Your site ($TARGET_ID) is no longer in the database."; problems=1
  fi
  if index_of_id "$OLD_ID" >/dev/null; then warn "The old Default site is still in the database."; problems=1; fi

  say ""
  if (( problems )); then
    say "The items marked WARN above are what differs from the expected result."
  else
    say "The database looks correct. The UI may still be loading or showing old data:"
    say "  wait a minute, then reload the page, or sign out and back in."
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  say "${C_BLD}UniFi OS Server: make an imported site the default site${C_OFF}"
  say "Not supported by Ubiquiti. Direct database edits may break with updates. Use at your own risk."

  step "Finding UniFi OS Server"
  check_basics
  find_service_unit
  find_service_user
  find_container
  find_mongo

  step "Finding sites"
  load_sites || fail "Could not read the site collection in $MONGO_DB."
  if [[ $(selectable_count) -eq 0 ]]; then
    warn "No site was found besides the Default site."
    if ask_yn "Did you import your site into UniFi OS Server?"; then
      search_for_site
    else
      say "Import your site first (site switcher > Import Site), then rerun this script."
      exit 1
    fi
  fi
  choose_site

  # Guardrails before any write.
  local i defaults=()
  for i in "${!S_ID[@]}"; do is_default "$i" && defaults+=("$i"); done
  [[ ${#defaults[@]} -eq 1 ]] || fail "Expected exactly one site with attr_hidden_id \"default\", found ${#defaults[@]}. Stopping without changes."
  OLD_ID="${S_ID[${defaults[0]}]}"
  i=$(index_of_id "$TARGET_ID") || fail "Chosen site not found."
  is_super "$i" && fail "The hidden system site cannot be chosen."
  [[ $TARGET_ID != "$OLD_ID" ]] || fail "That site is already the default."
  is_super "${defaults[0]}" && fail "The current default is the hidden system site. Stopping without changes."

  step "Moving the default flags to your site"
  update_one "db.site.updateOne({ _id: ObjectId(\"$OLD_ID\") }, { \$unset: { attr_hidden_id: \"\", attr_no_delete: \"\" } })" \
    || fail "Removing the default flags from the old Default did not change exactly one site. Nothing else was changed."
  ok "Removed the default flags from the old Default site."
  if ! update_one "db.site.updateOne({ _id: ObjectId(\"$TARGET_ID\") }, { \$set: { attr_hidden_id: \"default\", attr_no_delete: true } })"; then
    warn "Setting the default flags on your site did not change exactly one site."
    warn "No site holds the default flags right now. To restore the old Default, run this in the container's mongo shell (use $MONGO_DB):"
    say "db.site.updateOne({ _id: ObjectId(\"$OLD_ID\") }, { \$set: { attr_hidden_id: \"default\", attr_no_delete: true } })"
    exit 1
  fi
  ok "Set the default flags on your site."

  load_sites || fail "Could not re-read the sites."
  i=$(index_of_id "$TARGET_ID") || fail "Your site is missing after the update."
  [[ ${S_HID[i]} == "default" && ${S_NODEL[i]} == "true" ]] || fail "Verification failed: your site does not show the default flags."
  i=$(index_of_id "$OLD_ID") || fail "The old Default is missing after the update."
  [[ ${S_HID[i]} == "-" && ${S_NODEL[i]} == "-" ]] || fail "Verification failed: the old Default still shows default flags."
  ok "Verified."

  step "Restarting UniFi OS Server"
  restart_service

  step "Deleting the old Default site"
  load_sites || fail "Could not re-read the sites."
  i=$(index_of_id "$OLD_ID") || fail "The old Default is missing."
  is_super "$i" && fail "The old Default looks like the system site. Stopping without deleting."
  [[ $OLD_ID != "$TARGET_ID" ]] || fail "The old Default and your site are the same site. Stopping without deleting."
  [[ ${S_HID[i]} == "-" && ${S_NODEL[i]} == "-" ]] || fail "The old Default still shows default flags. Stopping without deleting."
  # The same records a delete in the UniFi UI removes (observed on UniFi OS
  # Server 5.1.42). History (admin_activity_log, alert, snapshots) and the
  # records the UI keeps (apgroup, ssl_inspection_certificate) are left alone.
  local c out
  for c in setting networkconf wlanconf wlangroup usergroup radiusprofile dpigroup privilege; do
    out=$(mongo_js "var r = db.$c.deleteMany({ \$or: [ { site_id: \"$OLD_ID\" }, { site_id: ObjectId(\"$OLD_ID\") } ] }); print('UOSDELETED ' + r.deletedCount);" 2>&1)
    [[ $out =~ UOSDELETED\ ([0-9]+) ]] || { say "$out"; fail "Deleting the old Default's $c records failed."; }
    say "  $c: ${BASH_REMATCH[1]} removed"
  done
  out=$(mongo_js "var r = db.site.deleteOne({ _id: ObjectId(\"$OLD_ID\") }); print('UOSDELETED ' + r.deletedCount);" 2>&1)
  [[ $out == *"UOSDELETED 1"* ]] || { say "$out"; fail "Deleting the old Default did not delete exactly one site."; }
  load_sites || fail "Could not re-read the sites."
  index_of_id "$OLD_ID" >/dev/null && fail "The old Default is still in the database."
  ok "The old Default site is deleted."

  step "Renaming your site to default"
  load_sites || fail "Could not re-read the sites."
  for i in "${!S_ID[@]}"; do
    if [[ ${S_ID[i]} != "$TARGET_ID" && ${S_NAME[i]} == "default" ]]; then
      fail "Another site is still named default (${S_ID[i]}). Stopping without renaming."
    fi
  done
  i=$(index_of_id "$TARGET_ID") || fail "Your site is missing."
  [[ ${S_HID[i]} == "default" ]] || fail "Your site no longer holds the default flags. Stopping without renaming."
  update_one "db.site.updateOne({ _id: ObjectId(\"$TARGET_ID\") }, { \$set: { name: \"default\" } })" \
    || fail "Renaming your site did not change exactly one site."
  load_sites || fail "Could not re-read the sites."
  i=$(index_of_id "$TARGET_ID") || fail "Your site is missing after the rename."
  [[ ${S_NAME[i]} == "default" ]] || fail "Verification failed: your site is not named default."
  ok "Your site's internal name is now default."

  # With one site left, Multi-Site Management is no longer needed. The UI
  # stores it in the super_mgmt setting; the restart below applies it.
  step "Turning off Multi-Site Management"
  MULTISITE_OFF=0
  local others=0 ms_line ms_id ms_val
  for i in "${!S_ID[@]}"; do
    is_super "$i" || others=$((others + 1))
  done
  if (( others != 1 )); then
    warn "Found $others sites besides the hidden system site. Leaving Multi-Site Management as it is."
  else
    ms_line=$(mongo_js 'var n = db.setting.count({ key: "super_mgmt" }); var s = db.setting.findOne({ key: "super_mgmt" }); if (n == 1) print("UOSMS " + s._id.str + " " + s.multiple_sites_enabled); else print("UOSMS count " + n);' 2>&1 | grep '^UOSMS ' | tail -n1)
    read -r _ ms_id ms_val <<<"$ms_line"
    if [[ $ms_val == "false" ]]; then
      MULTISITE_OFF=1
      ok "Multi-Site Management is already off."
    elif [[ $ms_val == "true" && $ms_id =~ ^[0-9a-f]{24}$ ]]; then
      if update_one "db.setting.updateOne({ _id: ObjectId(\"$ms_id\") }, { \$set: { multiple_sites_enabled: false } })"; then
        MULTISITE_OFF=1
        ok "Multi-Site Management turned off."
      else
        warn "Could not turn off Multi-Site Management. You can turn it off in the UI."
      fi
    else
      warn "Could not read the Multi-Site Management setting (${ms_line:-no answer}). Leaving it as it is."
    fi
  fi

  step "Restarting UniFi OS Server"
  restart_service

  step "Check the UniFi UI"
  say "Open the UniFi Network UI (reload the page if it was already open)."
  while ! ask_yn "Do you see only your site in UniFi OS Server?"; do
    diagnose
    say ""
  done
  say ""
  if (( MULTISITE_OFF == 0 )); then
    say "Optional: if you no longer need more than one site, you can now turn off Multi-Site Management in Settings > System > Site Management."
    say ""
  fi
  say "${C_YEL}${C_BLD}YOU ARE NOT DONE YET. Finish the migration:${C_OFF}"
  say "  1. Old server: select your site, Settings > System > Site Management > Export Site."
  say "     Skip the export and go to the device migration step."
  say "  2. Enter this server's inform address (copy it on the Overview tab, where the site status is)."
  say "  3. Wait until every device shows Connected on this server."
  say "  4. Only then clean up the old server. Forget factory-resets any device that can still reach it."
  say "  5. Take a fresh backup on this server."
  say ""
  say "Thanks for using me. Bye! <3"
}

main </dev/null
exit $?
UOS_EOF
