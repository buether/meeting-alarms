#!/usr/bin/env python3
"""Loud, persistent alarm shortly before a calendar meeting starts.

Subcommands:
  poll      Query upcoming events through EventKit and spawn an alarm for
            any that are due. launchd runs this every minute.
  alarm     Loop a sound and show the alarm window until dismissed.
  test      Arm a one-off alarm for the next poll and kick the launchd job.
  status    Poller health, recent alarms, and upcoming candidates.
  watchdog  Warn if the poller has not succeeded recently.
"""

import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent
CONFIG_PATH = REPO / "config.json"
LABEL = "com.buether.meeting-alarm"
STATE_DIR = Path.home() / "Library/Application Support/meeting-alarm"
LOG_DIR = Path.home() / "Library/Logs/meeting-alarm"
STATE_PATH = STATE_DIR / "state.json"
TEST_FLAG = STATE_DIR / "test-alarm-requested"
ALARM_LOCK = STATE_DIR / "alarm.lock"
DIALOG_BIN = REPO / "build/meeting-alarm-dialog"
CALENDAR_BIN = REPO / "build/MeetingAlarm.app/Contents/MacOS/meeting-alarm-calendar"
LOG_ROTATE_BYTES = 2_000_000

DEFAULTS = {
    "lead_seconds": 15,
    "poll_seconds": 60,
    "max_alarm_seconds": 900,
    "message": "Meeting starting",
    "volume": 75,
    "speak": True,
    "sound": "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Silk.m4r",
    "fallback_sound": "/System/Library/Sounds/Sosumi.aiff",
    "include_calendars": [],
    "expected_source": None,
    "failure_notice_after_seconds": 1800,
    "failure_notice_every_seconds": 14400,
    "fired_retention_seconds": 172800,
}

SKIP_STATUSES = ("declined", "tentative")

# A meeting still in progress alarms however late the Mac woke up. The lookback
# only bounds how far back a poll looks for one; the end time makes the decision.
LATE_LOOKBACK_SECONDS = 8 * 3600


class CalendarError(Exception):
    pass


def load_config():
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    except FileNotFoundError:
        pass
    return cfg


def load_state():
    try:
        state = json.loads(STATE_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        state = {}
    defaults = (
        ("fired", {}),
        ("last_ok", None),
        ("failing_since", None),
        ("last_error", None),
        ("last_failure_notice", 0),
        ("last_calendars_check", 0),
        ("polls", 0),
    )
    for key, default in defaults:
        state.setdefault(key, default)
    return state


def save_state(state, now, cfg):
    cutoff = now - cfg["fired_retention_seconds"]
    state["fired"] = {k: v for k, v in state["fired"].items() if v["start"] >= cutoff}
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    os.replace(tmp, STATE_PATH)


def log(message, name="poll"):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"{name}.log"
    if path.exists() and path.stat().st_size > LOG_ROTATE_BYTES:
        os.replace(path, path.with_suffix(".log.1"))
    with path.open("a") as handle:
        handle.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")


def parse_ts(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


def local_iso(ts):
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def safe_ts(iso):
    """None when a timestamp is missing or unparseable, so callers can fail safe."""
    try:
        return parse_ts(iso)
    except (AttributeError, TypeError, ValueError):
        return None


def event_title(event):
    return event.get("title") or "(untitled)"


def event_start_or(event, fallback):
    start = safe_ts(event.get("startDate"))
    return fallback if start is None else start


def event_sort_key(event):
    return event.get("startDate") or ""


def event_key(event):
    """Recurring occurrences share an id, so the start time is part of the key.

    An event with no readable start still needs a stable key, or it would alarm
    again every poll.
    """
    start = safe_ts(event.get("startDate"))
    stamp = int(start) if start is not None else "unknown"
    return f'{event.get("id") or event_title(event)}@{stamp}'


def my_status(event):
    """The current user's response, or 'pending' when EventKit marked no attendee as me."""
    mine = [a for a in event.get("attendees") or [] if a.get("isCurrentUser")]
    return mine[0].get("status", "unknown") if mine else "pending"


def eligible(event):
    """Non-timing filters. Returns (ok, reason)."""
    if event.get("isAllDay"):
        return False, "all-day"
    if event.get("status") == "canceled":
        return False, "canceled"
    attendees = event.get("attendees")
    if attendees is not None and not any(not a.get("isCurrentUser") for a in attendees):
        return False, "no other attendees"
    status = my_status(event)
    if status in SKIP_STATUSES:
        return False, f"my status {status}"
    return True, f"my status {status}"


def classify(event, now, fired, cfg):
    """Decide whether one calendar event should alarm at `now`. Returns (fire, reason).

    A meeting that has ended is the only reason to stay silent about an event
    that is otherwise eligible. Anything unreadable alarms, because a missed
    meeting costs more than a spurious alarm.
    """
    try:
        ok, reason = eligible(event)
        if not ok:
            return False, reason
        if event_key(event) in fired:
            return False, "already fired"
        end = safe_ts(event.get("endDate"))
        if end is not None and now >= end:
            return False, "already ended"
        start = safe_ts(event.get("startDate"))
        if start is None:
            return True, f"{reason}, start time unreadable"
        delta = start - now
        if delta >= cfg["lead_seconds"] + cfg["poll_seconds"]:
            return False, f"starts in {int(delta)}s"
        if delta < 0:
            return True, f"{reason}, started {int(-delta)}s ago and still running"
        return True, f"{reason}, starts in {int(delta)}s"
    except Exception as err:
        return True, f"unreadable event ({type(err).__name__}: {err})"


def select_due(events, now, fired, cfg):
    return [e for e in events if classify(e, now, fired, cfg)[0]]


def utc_iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_calendar(*args):
    try:
        result = subprocess.run(
            [str(CALENDAR_BIN), *args], capture_output=True, text=True, timeout=120
        )
    except FileNotFoundError:
        raise CalendarError(f"{CALENDAR_BIN} not built (run ./install.sh)")
    except subprocess.TimeoutExpired:
        raise CalendarError("calendar query timed out (waiting on a permission prompt?)")
    if result.returncode != 0:
        raise CalendarError(result.stderr.strip() or f"calendar query exit {result.returncode}")
    try:
        return json.loads(result.stdout or "[]")
    except json.JSONDecodeError as err:
        raise CalendarError(f"calendar output was not JSON: {err}")


def fetch_events(cfg, start, end):
    args = ["events", "--from", utc_iso(start), "--to", utc_iso(end)]
    if cfg["include_calendars"]:
        args += ["--include-calendars", ",".join(cfg["include_calendars"])]
    return run_calendar(*args)


def within(events, lo, hi):
    """Events whose start falls in [lo, hi). An unreadable start is kept for classify."""
    kept = []
    for event in events:
        start = safe_ts(event.get("startDate"))
        if start is None or lo <= start < hi:
            kept.append(event)
    return kept


def fire_window(now, cfg):
    return now - LATE_LOOKBACK_SECONDS, now + cfg["lead_seconds"] + cfg["poll_seconds"] + 60


def check_calendars(cfg):
    calendars = run_calendar("calendars")
    if not any(c.get("source") == cfg["expected_source"] for c in calendars):
        raise CalendarError(
            f'no calendar from source "{cfg["expected_source"]}"; is the account still signed in?'
        )


NOTICE_SCRIPT = """on run argv
display dialog (item 1 of argv) with title (item 2 of argv) buttons {"OK"} default button 1 with icon stop giving up after ((item 3 of argv) as integer)
end run"""


def notify(message, title="Meeting alarm", seconds=300):
    """Plain dialog with no sound, detached so the caller can exit."""
    subprocess.Popen(
        ["osascript", "-e", NOTICE_SCRIPT, message, title, str(seconds)],
        start_new_session=True, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def maybe_notify_failure(state, now, cfg):
    failing_for = now - state["failing_since"]
    since_notice = now - state["last_failure_notice"]
    if failing_for < cfg["failure_notice_after_seconds"]:
        return
    if since_notice < cfg["failure_notice_every_seconds"]:
        return
    since = time.strftime("%H:%M", time.localtime(state["failing_since"]))
    notify(
        f"Meeting alarm has not been able to read the calendar since {since}.\n\n"
        f"{state['last_error']}\n\nRun: meeting-alarm status"
    )
    state["last_failure_notice"] = now


def spawn_alarm(due):
    title = "; ".join(event_title(e) for e in due)
    starts = [ts for ts in (safe_ts(e.get("startDate")) for e in due) if ts is not None]
    start = min(starts) if starts else time.time()
    url = next((e["meetingUrl"] for e in due if e.get("meetingUrl")), "")
    cmd = [sys.executable, str(Path(__file__).resolve()), "alarm",
           "--title", title, "--start", str(int(start)), "--url", url]
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with (LOG_DIR / "alarm.log").open("a") as out:
        subprocess.Popen(cmd, start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=out, stderr=subprocess.STDOUT)


def poll(args):
    cfg = load_config()
    now = parse_ts(args.now) if args.now else time.time()
    state = load_state()
    state["polls"] += 1
    try:
        if args.events_file:
            events = json.loads(Path(args.events_file).read_text())
        else:
            lo, hi = fire_window(now, cfg)
            events = fetch_events(cfg, lo, hi)
        # EventKit matches events overlapping the window, so one that started
        # before the lookback comes back too.
        events = within(events, *fire_window(now, cfg))
        if cfg["expected_source"] and now - state["last_calendars_check"] > 3600:
            check_calendars(cfg)
            state["last_calendars_check"] = now
    except CalendarError as err:
        state["last_error"] = str(err)
        state["failing_since"] = state["failing_since"] or now
        maybe_notify_failure(state, now, cfg)
        if not args.dry_run:
            save_state(state, now, cfg)
        log(f"FAIL {err}")
        print(f"FAIL {err}", file=sys.stderr)
        return 1
    state.update(last_ok=now, failing_since=None, last_error=None)
    due = select_due(events, now, state["fired"], cfg)
    if args.dry_run:
        for event in sorted(events, key=event_sort_key):
            fire, reason = classify(event, now, state["fired"], cfg)
            when = local_iso(event_start_or(event, now))
            print(f'{"FIRE" if fire else "skip"}  {when}  {event_title(event)}  ({reason})')
        print(f"{len(events)} events in window, {len(due)} due")
        return 0
    if TEST_FLAG.exists():
        TEST_FLAG.unlink()
        due.append({"id": "test", "title": "TEST ALARM", "meetingUrl": "https://meet.google.com/",
                    "startDate": local_iso(now + cfg["lead_seconds"])})
    log(f"ok events={len(events)} due={[event_key(e) for e in due]}")
    if due:
        spawn_alarm(due)
        for event in due:
            state["fired"][event_key(event)] = {
                "at": now, "start": event_start_or(event, now), "title": event_title(event),
            }
    save_state(state, now, cfg)
    return 0


def get_volume():
    """Current output level and mute state, or None when the device has no software volume."""
    result = subprocess.run(["osascript", "-e", "get volume settings"], capture_output=True, text=True)
    settings = {}
    for part in result.stdout.strip().split(","):
        key, _, value = part.strip().partition(":")
        settings[key] = value
    level = settings.get("output volume")
    if not level or level == "missing value":
        return None
    return {"level": int(level), "muted": settings.get("output muted") == "true"}


def set_volume(level, muted):
    subprocess.run(
        ["osascript", "-e", f"set volume output volume {level}",
         "-e", f"set volume {'with' if muted else 'without'} output muted"],
        capture_output=True,
    )


def describe_sound(cfg):
    sound = resolve_sound(cfg)
    if sound is None:
        return "MISSING - the alarm will speak once but not loop"
    if sound != cfg["sound"]:
        return f"{Path(sound).name} (fallback; {cfg['sound']} is not on disk)"
    return Path(sound).name


def resolve_sound(cfg):
    for candidate in (cfg["sound"], cfg["fallback_sound"]):
        if candidate and Path(candidate).exists():
            return candidate
    return None


def start_sound_loop(sound, owner_pid):
    """Repeat the sound until the owner exits or the loop's process group is killed."""
    script = 'while kill -0 "$1" 2>/dev/null; do afplay "$0"; sleep 0.3; done'
    return subprocess.Popen(
        ["/bin/bash", "-c", script, sound, str(owner_pid)],
        start_new_session=True, stdin=subprocess.DEVNULL,
    )


DIALOG_SCRIPT = """on run argv
try
tell me to activate
end try
display dialog (item 1 of argv) with title "Meeting starting" buttons {"Dismiss"} default button 1 with icon caution giving up after ((item 2 of argv) as integer)
end run"""

APPLESCRIPT_USER_CANCELED = "-128"

current_dialog = None


def show_dialog(headline, detail, url, give_up_after):
    """Show the alarm window until dismissed or timed out.

    Uses the native window from dialog/main.swift when install.sh has built
    it, which floats above full-screen apps; otherwise an osascript dialog.
    Returns 'dismissed', 'gave_up', 'killed', or 'error'.
    """
    global current_dialog
    native = DIALOG_BIN.exists()
    if native:
        cmd = [str(DIALOG_BIN), headline, detail, str(give_up_after), url]
    else:
        text = f"{headline}\n\n{detail}" + (f"\n{url}" if url else "")
        cmd = ["osascript", "-e", DIALOG_SCRIPT, text, str(give_up_after)]
    current_dialog = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = current_dialog.communicate()
    code = current_dialog.returncode
    current_dialog = None
    if code < 0:
        return "killed"
    if native:
        return {0: "dismissed", 2: "gave_up"}.get(code, "error")
    if code != 0:
        return "dismissed" if APPLESCRIPT_USER_CANCELED in err else "error"
    return "gave_up" if "gave up:true" in out else "dismissed"


def alarm(args):
    cfg = load_config()
    if args.max_seconds is not None:
        cfg["max_alarm_seconds"] = args.max_seconds
    if args.volume is not None:
        cfg["volume"] = args.volume
    def stop(signum, _frame):
        log(f"terminated by signal {signum}", name="alarm")
        sys.exit(0)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)

    loop = None
    saved = None
    primary = False
    deadline = args.start + cfg["max_alarm_seconds"] if cfg["max_alarm_seconds"] else None
    log(f"spawned title={args.title!r} start={args.start}", name="alarm")
    try:
        # The poll spawns up to a minute early; sound exactly lead_seconds before start.
        wait = args.start - cfg["lead_seconds"] - time.time()
        if wait > 0:
            time.sleep(wait)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Meetings a minute apart put two alarms on screen at once. Only the
        # lock holder raises the volume and loops the sound.
        lock = open(ALARM_LOCK, "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            primary = True
        except BlockingIOError:
            primary = False
        log(f"ringing primary={primary}", name="alarm")
        subprocess.Popen(["caffeinate", "-u", "-t", "3"], stdin=subprocess.DEVNULL)
        if primary:
            saved = get_volume()
            if saved:
                set_volume(cfg["volume"], muted=False)
            if cfg["speak"]:
                subprocess.run(["say", cfg["message"]])
            sound = resolve_sound(cfg)
            if sound:
                loop = start_sound_loop(sound, os.getpid())
            else:
                log("no sound file found", name="alarm")
        errors = 0
        while True:
            remaining = None if deadline is None else deadline - time.time()
            if remaining is not None and remaining <= 0:
                log("stopped at max_alarm_seconds", name="alarm")
                break
            give_up = 60 if remaining is None else max(1, min(60, int(remaining)))
            outcome = show_dialog(cfg["message"], args.title, args.url, give_up)
            if outcome == "gave_up":
                continue
            if outcome == "error":
                errors += 1
                if errors >= 5:
                    log("dialog failed 5 times, stopping", name="alarm")
                    break
                time.sleep(2)
                continue
            log(outcome, name="alarm")
            break
    finally:
        if current_dialog:
            current_dialog.terminate()
        if loop:
            os.killpg(loop.pid, signal.SIGTERM)
        if saved:
            # Someone who turned the volume down by hand keeps their level.
            current = get_volume()
            if current and current["level"] == cfg["volume"] and not current["muted"]:
                set_volume(saved["level"], saved["muted"])
    return 0


def test(args):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    TEST_FLAG.touch()
    result = subprocess.run(
        ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{LABEL}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"kickstart failed: {result.stderr.strip()}")
        print("The test alarm will fire on the next scheduled poll instead.")
        return 1
    print("Test alarm requested. It should ring within a few seconds.")
    return 0


def status(args):
    cfg = load_config()
    state = load_state()
    now = time.time()
    result = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True, text=True
    )
    if result.returncode != 0:
        print("launchd: NOT LOADED (run install.sh)")
    else:
        for line in result.stdout.splitlines():
            if any(marker in line for marker in ("state =", "last exit code =", "runs =")):
                print("launchd:", line.strip())

    def age(ts):
        return "never" if not ts else f"{int(now - ts)}s ago"

    print(f"last successful poll: {age(state['last_ok'])}  (polls: {state['polls']})")
    if state["failing_since"]:
        since = time.strftime("%Y-%m-%d %H:%M", time.localtime(state["failing_since"]))
        print(f"FAILING since {since}: {state['last_error']}")
    print(f"sound: {describe_sound(cfg)}")
    recent = sorted(state["fired"].items(), key=lambda kv: kv[1]["start"])[-5:]
    print("recent alarms:" if recent else "recent alarms: none")
    for _, info in recent:
        print(f"  {time.strftime('%a %H:%M', time.localtime(info['start']))}  {info['title']}")
    try:
        lo, hi = now - LATE_LOOKBACK_SECONDS, now + 8 * 3600
        events = within(fetch_events(cfg, lo, hi), lo, hi)
    except CalendarError as err:
        print(f"calendar query failed: {err}")
        return 1
    print(f"next 8 hours ({len(events)} events):" if events else "next 8 hours: no events")
    for event in sorted(events, key=event_sort_key):
        ok, reason = eligible(event)
        fired = event_key(event) in state["fired"]
        verdict = "fired" if fired else ("alarm" if ok else "skip")
        when = time.strftime("%H:%M", time.localtime(event_start_or(event, now)))
        print(f"  {when}  {verdict:5}  {event_title(event)}  ({reason})")
    return 0


def watchdog(args):
    time.sleep(args.wait)
    state = load_state()
    now = time.time()
    if state["last_ok"] is not None and now - state["last_ok"] <= args.max_age:
        log("watchdog: ok")
        return 0
    last = "never" if state["last_ok"] is None else time.strftime(
        "%Y-%m-%d %H:%M", time.localtime(state["last_ok"])
    )
    notify(f"Meeting alarm poller has not succeeded since {last}.\n\nRun: meeting-alarm status")
    log(f"watchdog: stale, last_ok={last}")
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("poll")
    p.add_argument("--dry-run", action="store_true", help="print decisions, write nothing, alarm nothing")
    p.add_argument("--now", help="pretend it is this ISO 8601 time (same day as today)")
    p.add_argument("--events-file", help="read events JSON from a file instead of querying the calendar")
    p.set_defaults(func=poll)

    p = sub.add_parser("alarm")
    p.add_argument("--title", required=True)
    p.add_argument("--start", type=int, required=True, help="meeting start, epoch seconds")
    p.add_argument("--url", default="", help="meeting link for the Join button")
    p.add_argument("--max-seconds", type=int, help="override max_alarm_seconds (0 = until dismissed)")
    p.add_argument("--volume", type=int, help="override output volume 0-100")
    p.set_defaults(func=alarm)

    p = sub.add_parser("test")
    p.set_defaults(func=test)

    p = sub.add_parser("status")
    p.set_defaults(func=status)

    p = sub.add_parser("watchdog")
    p.add_argument("--max-age", type=int, default=3 * 3600, help="seconds since last successful poll")
    p.add_argument("--wait", type=int, default=90, help="seconds to sleep first so a wake-time poll can finish")
    p.set_defaults(func=watchdog)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
