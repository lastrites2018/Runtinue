#!/bin/zsh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  print -u2 "제거는 sudo로 실행해야 합니다"
  exit 77
fi

sleep_state() {
  local output
  output=$(/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null) || {
    print "unknown"
    return
  }
  if print -r -- "${output}" | /usr/bin/grep -q '"SleepDisabled" = No'; then
    print "normal"
  elif print -r -- "${output}" | /usr/bin/grep -q '"SleepDisabled" = Yes'; then
    print "disabled"
  else
    print "unknown"
  fi
}

run_as_console_user() {
  local console_uid=$1
  shift
  /bin/launchctl asuser "${console_uid}" /usr/bin/sudo -u "#${console_uid}" "$@"
}

console_uid=$(/usr/bin/stat -f %u /dev/console 2>/dev/null || print 0)
cli=/usr/local/bin/runtinue
if [[ "${console_uid}" -ge 500 && -x "${cli}" ]]; then
  run_as_console_user "${console_uid}" "${cli}" adaptive disable >/dev/null 2>&1 || true
  run_as_console_user "${console_uid}" "${cli}" desk disable >/dev/null 2>&1 || true
  run_as_console_user "${console_uid}" "${cli}" stop >/dev/null 2>&1 || true
fi

if [[ "$(sleep_state)" == "disabled" && ! -f "/Library/Application Support/io.github.lastrites2018.runtinue/helper/lease.json" ]]; then
  print -u2 "Runtinue 소유 lease 없이 SleepDisabled가 켜져 있어 제거하지 않습니다"
  exit 70
fi

for _ in {1..100}; do
  state=$(sleep_state)
  [[ "${state}" == "normal" ]] && break
  [[ "${state}" == "unknown" ]] && break
  /bin/launchctl kickstart -k system/io.github.lastrites2018.runtinue.helper >/dev/null 2>&1 || true
  /bin/sleep 1
done

if [[ "$(sleep_state)" != "normal" ]]; then
  print -u2 "정상 수면 상태를 확인하지 못했습니다. 복구 책임을 보존하기 위해 제거하지 않습니다"
  exit 70
fi

if [[ "${console_uid}" -ge 500 ]]; then
  /bin/launchctl bootout "gui/${console_uid}" /Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist >/dev/null 2>&1 || true
fi
/bin/launchctl bootout system /Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist >/dev/null 2>&1 || true

if [[ "$(sleep_state)" != "normal" ]]; then
  /bin/launchctl bootstrap system /Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist >/dev/null 2>&1 || true
  print -u2 "서비스 종료 뒤 정상 수면 상태가 바뀌어 제거를 중단합니다"
  exit 70
fi

/bin/rm -f -- \
  /usr/local/bin/runtinue \
  /usr/local/bin/runtinue-hook \
  /usr/local/bin/runtinue-activity \
  /Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist \
  /Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist
/bin/rm -rf -- \
  /Applications/Runtinue.app \
  "/Library/Application Support/io.github.lastrites2018.runtinue" \
  /Library/Logs/io.github.lastrites2018.runtinue
/usr/sbin/pkgutil --forget io.github.lastrites2018.runtinue.pkg >/dev/null 2>&1 || true

print "Runtinue 시스템 구성요소를 제거했습니다"
print "사용자 config, session, history 파일은 보존했습니다"
