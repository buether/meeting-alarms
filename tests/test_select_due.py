import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import meeting_alarm as ma  # noqa: E402

NOW = 1_800_000_000.0
CFG = {**ma.DEFAULTS, "lead_seconds": 60, "poll_seconds": 60}


def iso_utc(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def event(start_offset, duration=1800, me="accepted", others=True, all_day=False,
          status="confirmed", event_id="abc", now=NOW, title="Standup", start_override=None):
    attendees = []
    if others:
        attendees.append({"email": "them@example.com", "status": "accepted", "isCurrentUser": False})
    if me is not None:
        attendees.append({"email": "me@example.com", "status": me, "isCurrentUser": True})
    start = now + start_offset
    return {
        "id": event_id,
        "title": title,
        "startDate": start_override or iso_utc(start),
        "endDate": iso_utc(start + duration),
        "isAllDay": all_day,
        "status": status,
        "attendees": attendees,
    }


def fires(ev, fired=None, now=NOW):
    return ma.classify(ev, now, fired or {}, CFG)[0]


class WindowTests(unittest.TestCase):
    def test_fires_just_inside_lead_plus_poll(self):
        self.assertTrue(fires(event(119)))

    def test_does_not_fire_at_lead_plus_poll(self):
        self.assertFalse(fires(event(120)))

    def test_fires_when_poll_ran_late(self):
        self.assertTrue(fires(event(59)))

    def test_fires_long_after_start_while_still_running(self):
        self.assertTrue(fires(event(-3600, duration=7200)))

    def test_does_not_fire_after_meeting_ended(self):
        self.assertFalse(fires(event(-100, duration=60)))

    def test_does_not_fire_once_a_long_meeting_ends(self):
        self.assertFalse(fires(event(-7201, duration=7200)))


class DedupeTests(unittest.TestCase):
    def test_already_fired_key_is_skipped(self):
        ev = event(90)
        self.assertFalse(fires(ev, fired={ma.event_key(ev): {}}))

    def test_moved_meeting_gets_new_key(self):
        original = event(90)
        moved = event(90 + 600)
        self.assertNotEqual(ma.event_key(original), ma.event_key(moved))

    def test_recurring_occurrences_differ_by_start(self):
        today = event(90, event_id="recurring")
        tomorrow = event(90 + 86400, event_id="recurring")
        self.assertNotEqual(ma.event_key(today), ma.event_key(tomorrow))

    def test_two_meetings_same_minute_both_due(self):
        due = ma.select_due([event(90, event_id="a"), event(95, event_id="b")], NOW, {}, CFG)
        self.assertEqual({e["id"] for e in due}, {"a", "b"})


class FilterTests(unittest.TestCase):
    def test_all_day_skipped(self):
        self.assertFalse(fires(event(90, all_day=True)))

    def test_canceled_skipped(self):
        self.assertFalse(fires(event(90, status="canceled")))

    def test_solo_event_skipped(self):
        self.assertFalse(fires(event(90, others=False)))

    def test_declined_skipped(self):
        self.assertFalse(fires(event(90, me="declined")))

    def test_tentative_skipped(self):
        self.assertFalse(fires(event(90, me="tentative")))

    def test_pending_fires(self):
        self.assertTrue(fires(event(90, me="pending")))

    def test_unknown_status_fires(self):
        self.assertTrue(fires(event(90, me="unknown")))

    def test_no_current_user_attendee_fires(self):
        self.assertTrue(fires(event(90, me=None)))

    def test_reason_names_my_status(self):
        _, reason = ma.classify(event(90, me="pending"), NOW, {}, CFG)
        self.assertIn("pending", reason)


class WithinTests(unittest.TestCase):
    def test_keeps_only_starts_inside_window(self):
        too_old = -(ma.LATE_LOOKBACK_SECONDS + 1)
        events = [event(too_old, event_id="early"), event(-500, event_id="in"), event(200, event_id="late")]
        lo, hi = ma.fire_window(NOW, CFG)
        self.assertEqual([e["id"] for e in ma.within(events, lo, hi)], ["in"])

    def test_upper_bound_is_exclusive(self):
        lo, hi = ma.fire_window(NOW, CFG)
        self.assertEqual(ma.within([event(hi - NOW)], lo, hi), [])


class FailSafeTests(unittest.TestCase):
    """An unreadable event alarms; only a known end time in the past is silent."""

    def without(self, key, **kw):
        return {k: v for k, v in event(90, **kw).items() if k != key}

    def test_missing_title_fires(self):
        self.assertTrue(fires(self.without("title")))

    def test_null_title_fires(self):
        self.assertTrue(fires(event(90, title=None)))

    def test_missing_end_date_fires(self):
        self.assertTrue(fires(self.without("endDate")))

    def test_unreadable_start_fires(self):
        self.assertTrue(fires(event(90, start_override="not-a-date")))

    def test_unreadable_start_keeps_a_stable_key(self):
        """A key that changed per poll would alarm every 60 seconds."""
        first = event(90, start_override="not-a-date")
        second = event(90, start_override="not-a-date")
        self.assertEqual(ma.event_key(first), ma.event_key(second))
        self.assertFalse(fires(second, fired={ma.event_key(first): {}}))

    def test_missing_attendees_fires(self):
        self.assertTrue(fires(self.without("attendees")))

    def test_explicitly_empty_attendees_is_skipped(self):
        self.assertFalse(fires(event(90, others=False, me=None)))

    def test_classify_alarms_when_a_field_has_the_wrong_type(self):
        fire, reason = ma.classify({"id": "a", "attendees": "not-a-list"}, NOW, {}, CFG)
        self.assertTrue(fire)
        self.assertIn("unreadable event", reason)

    def test_within_keeps_an_unreadable_start(self):
        ev = event(90, start_override="not-a-date")
        lo, hi = ma.fire_window(NOW, CFG)
        self.assertEqual(ma.within([ev], lo, hi), [ev])


class TimestampTests(unittest.TestCase):
    def test_parses_zulu(self):
        self.assertEqual(ma.parse_ts("2026-09-15T21:00:00Z"), 1_789_506_000.0)

    def test_parses_offset(self):
        self.assertEqual(ma.parse_ts("2026-09-15T14:00:00-07:00"), 1_789_506_000.0)


if __name__ == "__main__":
    unittest.main()
