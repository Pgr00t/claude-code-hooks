#!/usr/bin/env python3
"""Tests for ~/.claude/hooks/metrics-row.py, the --outcomes pass in particular: the three outcome rules
(QA bounces from a Jira changelog, production incidents from Sentry, human review comments from GitHub),
the fetchers that stand in for Jira and Sentry, and the CSV rewrite that fills only the three outcome
columns. Nothing here reaches the network: every source is a fake handed in as a fetcher or a runner.

  python3 -I ~/.claude/hooks/tests/test-metrics-row.py          # exit 0 when every case passes
  HOOK=/path/to/metrics-row.py python3 -I .../test-metrics-row.py
"""
import csv
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HOOK = os.environ.get("HOOK") or os.path.expanduser("~/.claude/hooks/metrics-row.py")
spec = importlib.util.spec_from_file_location("metrics_row", HOOK)
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

HEADER_OLD = ("repo,ticket,branch,pr,pr_state,round_date,checks,rounds,correct_checks,mutants_run,mutants_survived,"
              "judge_fails,qa_bounces,human_approvals,human_review_comments,changes_requested,plan_approved_utc,"
              "packet_utc,pushed_utc,pr_opened_utc,pr_merged_utc,plan_to_push_min,open_to_merge_h,spec_started_utc,"
              "session_tokens,judge_tokens,interruptions,note")
ROW_OLD = ("instill-app-api,IT-2254 (readiness),IT-2254-beats-readiness,1453,MERGED,2026-10-21,24,1,1,8,2,0,1,1,0,0,,"
           "2026-10-21T15:39Z,2026-10-21T15:43Z,2026-10-21T15:43Z,2026-10-22T12:22Z,,20.6,,,,,"
           "\"no plan file; qa_bounces is ticket-level, typed\"")
ROW_NEW = ("instill-app-api,IT-2263/IT-2264,IT-2263-IT-2264-team-uuid-company-scoping,1462,MERGED,2026-10-27,10,1,1,14,1,0,,1,0,0,"
           "2026-10-27T15:00Z,2026-10-27T15:12Z,2026-10-27T15:16Z,2026-10-27T15:17Z,2026-10-28T19:45Z,16,28.5,,,,,"
           "\"two tickets, one PR\"")
ROW_NOKEY = ("instill-app-api,zero-red-unit-suite,zero-red-unit-suite,1464,MERGED,2026-10-27,5,1,0,11,1,0,,1,0,0,"
             "2026-10-27T17:46Z,2026-10-27T18:07Z,2026-10-27T18:05Z,2026-10-27T18:06Z,2026-10-28T19:46Z,19,25.7,"
             "2026-10-27T17:44Z,286196,336144,0,Move 2")


def history(when, frm, to, field="status"):
    return {"created": when, "items": [{"field": field, "fromString": frm, "toString": to}]}


class Bounces(unittest.TestCase):
    AFTER = "2026-10-27T15:17Z"  # the PR opened

    def test_review_or_later_back_to_an_earlier_status_after_the_pr_opened_is_one_bounce(self):
        hs = [history("2026-10-29T23:21:06.772-0700", "In Review (code review)", "In QA"),
              history("2026-10-30T02:00:00.000-0700", "In QA", "Ready for Dev")]
        self.assertEqual(mr.count_bounces(hs, self.AFTER), 1)

    def test_every_late_to_early_pair_counts_including_done_to_reopened(self):
        hs = [history("2026-10-30T02:00:00.000-0700", "Done", "Reopened"),
              history("2026-10-31T02:00:00.000-0700", "Ready for release on Prod", "In Progress"),
              history("2026-11-01T02:00:00.000-0700", "In Review (code review)", "Scoping - PRD")]
        self.assertEqual(mr.count_bounces(hs, self.AFTER), 3)

    def test_forward_moves_and_non_status_items_do_not_count(self):
        hs = [history("2026-10-27T10:04:49.957-0700", "Ready for Dev", "In Progress"),
              history("2026-10-27T10:05:15.298-0700", "In Progress", "In Review (code review)"),
              history("2026-10-29T23:21:06.490-0700", "", "Ranked higher", field="Rank"),
              history("2026-10-29T23:21:06.772-0700", "In Review (code review)", "In QA")]
        self.assertEqual(mr.count_bounces(hs, self.AFTER), 0)

    def test_a_bounce_before_the_pr_opened_is_churn_not_an_escape(self):
        hs = [history("2026-10-27T07:00:00.000-0700", "In Review (code review)", "In Progress")]  # 14:00Z < 15:17Z
        self.assertEqual(mr.count_bounces(hs, self.AFTER), 0)
        hs = [history("2026-10-27T08:30:00.000-0700", "In Review (code review)", "In Progress")]  # 15:30Z > 15:17Z
        self.assertEqual(mr.count_bounces(hs, self.AFTER), 1)

    def test_jira_changelog_reads_the_issue_and_pages_when_the_embedded_log_is_short(self):
        calls = []

        def fetch(path, params=None):
            calls.append((path, dict(params or {})))
            if path == "issue/IT-2263":
                return {"key": "IT-2263", "changelog": {"total": 3, "histories": [history("a", "x", "y")]}}
            if path == "issue/IT-2263/changelog":
                start = int(params.get("startAt", 0))
                if start == 0:
                    return {"values": [history("a", "x", "y"), history("b", "x", "y")], "isLast": False}
                return {"values": [history("c", "x", "y")], "isLast": True}
            raise AssertionError(path)

        hs = mr.jira_changelog("IT-2263", fetch)
        self.assertEqual([h["created"] for h in hs], ["a", "b", "c"])
        self.assertEqual(calls[0][0], "issue/IT-2263")
        self.assertEqual(calls[0][1].get("expand"), "changelog")

    def test_jira_changelog_uses_the_embedded_log_when_it_is_complete(self):
        def fetch(path, params=None):
            self.assertEqual(path, "issue/IT-2264")
            return {"key": "IT-2264", "changelog": {"total": 2, "histories": [history("a", "x", "y"), history("b", "x", "y")]}}

        self.assertEqual(len(mr.jira_changelog("IT-2264", fetch)), 2)


def issue(id_, short, first_seen, project="instill-app-api", annotations=None):
    return {"id": str(id_), "shortId": short, "firstSeen": first_seen, "project": {"slug": project},
            "annotations": annotations or []}


def event(*filenames):
    frames = [{"filename": f, "function": "fn", "lineNo": 1, "inApp": not f.startswith("celery/")} for f in filenames]
    return {"eventID": "e", "entries": [{"type": "exception", "data": {"values": [{"type": "KeyError", "stacktrace": {"frames": frames}}]}}]}


class Incidents(unittest.TestCase):
    SINCE = "2026-10-30T06:14Z"
    CHANGED = ["app/queue/celery.py", "app/queue/task/_sync_calendar_events.py", "tests/unit/x.py"]

    def fetch_for(self, issues, events, external=None, calls=None):
        def fetch(path, params=None):
            if calls is not None:
                calls.append((path, dict(params or {})))
            if path.startswith("projects/instillai/") and path.endswith("/issues/"):
                slug = path.split("/")[2]
                return [i for i in issues if i["project"]["slug"] == slug]
            if path.startswith("issues/") and path.endswith("/events/latest/"):
                return events[path.split("/")[1]]
            if path.startswith("organizations/instillai/issues/") and path.endswith("/external-issues/"):
                return (external or {}).get(path.split("/")[3], [])
            raise AssertionError(path)
        return fetch

    def test_frame_in_a_changed_file_after_beta_counts_once(self):
        issues = [issue(1, "INSTILL-APP-API-WORKER-TQ", "2026-11-02T15:49:04.805Z", "instill-app-api-worker")]
        events = {"1": event("celery/worker/consumer/consumer.py", "/opt/app/app/queue/celery.py")}
        n, ids = mr.sentry_incidents(self.CHANGED, [], self.SINCE, ["instill-app-api", "instill-app-api-worker"],
                                     self.fetch_for(issues, events))
        self.assertEqual((n, ids), (1, ["INSTILL-APP-API-WORKER-TQ"]))

    def test_first_seen_before_beta_or_frames_elsewhere_do_not_count(self):
        issues = [issue(1, "A-1", "2026-10-30T06:13:59Z"), issue(2, "A-2", "2026-10-31T00:00:00Z")]
        events = {"1": event("app/queue/celery.py"), "2": event("app/services/other.py", "celery/app.py")}
        n, ids = mr.sentry_incidents(self.CHANGED, ["IT-2263"], self.SINCE, ["instill-app-api"], self.fetch_for(issues, events))
        self.assertEqual((n, ids), (0, []))

    def test_a_jira_link_naming_the_ticket_counts_without_a_frame_match(self):
        issues = [issue(3, "A-3", "2026-10-31T00:00:00Z"), issue(4, "A-4", "2026-10-31T00:00:00Z", annotations=[{"displayName": "IT-2264"}])]
        events = {"3": event("app/services/other.py"), "4": event("app/services/other.py")}
        external = {"3": [{"key": "IT-2263", "displayName": "IT-2263"}]}
        n, ids = mr.sentry_incidents(self.CHANGED, ["IT-2263", "IT-2264"], self.SINCE, ["instill-app-api"],
                                     self.fetch_for(issues, events, external))
        self.assertEqual((n, ids), (2, ["A-3", "A-4"]))

    def test_the_listing_asks_for_the_beta_environment_of_each_project(self):
        calls = []
        mr.sentry_incidents(self.CHANGED, [], self.SINCE, ["instill-app-api", "instill-app-api-worker"], self.fetch_for([], {}, calls=calls))
        listing = [(p, q) for p, q in calls if p.endswith("/issues/")]
        self.assertEqual([p for p, _ in listing], ["projects/instillai/instill-app-api/issues/", "projects/instillai/instill-app-api-worker/issues/"])
        for _, q in listing:
            self.assertEqual(q.get("environment"), "beta")
            self.assertIn("firstSeen:>2026-10-30", q.get("query", ""))

    def test_frames_match_by_path_suffix_either_way_but_not_by_basename(self):
        self.assertTrue(mr.frame_hits("/app/app/queue/celery.py", ["app/queue/celery.py"]))
        self.assertTrue(mr.frame_hits("queue/celery.py", ["app/queue/celery.py"]))
        self.assertFalse(mr.frame_hits("celery.py", ["app/queue/celery.py"]))
        self.assertFalse(mr.frame_hits("app/queue/celery.py", ["other/app/queue/celery.pyc"]))


class BetaReached(unittest.TestCase):
    def test_first_beta_merge_that_contains_the_merge_commit_gives_the_time(self):
        def run(args, cwd=None):
            if args[:3] == ["git", "-C", "/r"] and args[3] == "log":
                return "aaa 2026-10-28T10:00:00+05:30\nbbb 2026-10-30T11:44:11+05:30\nccc 2026-11-05T09:00:00+05:30\n"
            if args[3] == "merge-base":
                return "m1\n" if args[5] in ("bbb", "ccc") else "zzz\n"
            if args[3] == "rev-parse":
                return "m1\n"
            if args[3] == "fetch":
                return ""
            raise AssertionError(args)
        self.assertEqual(mr.beta_reached_utc("/r", "m1", run), "2026-10-30T06:14Z")

    def test_blank_when_no_beta_merge_contains_it_yet(self):
        def run(args, cwd=None):
            if args[3] == "log":
                return "aaa 2026-10-28T10:00:00+05:30\n"
            return ""
        self.assertEqual(mr.beta_reached_utc("/r", "m1", run), "")


class ReviewComments(unittest.TestCase):
    def test_threads_conversation_and_review_text_count_approvals_and_the_author_do_not(self):
        def run(args, cwd=None):
            if args[:3] == ["gh", "pr", "view"]:
                return json.dumps({"state": "MERGED", "createdAt": "2026-11-01T14:41:00Z", "mergedAt": "2026-11-02T15:29:37Z", "author": {"login": "ParasInstill"}})
            endpoint = args[2]
            if endpoint.endswith("/reviews"):
                return json.dumps([{"user": {"login": "hyg1997", "type": "User"}, "state": "APPROVED", "body": ""},
                                   {"user": {"login": "iam-abbas", "type": "User"}, "state": "COMMENTED", "body": "one thought"},
                                   {"user": {"login": "ParasInstill", "type": "User"}, "state": "COMMENTED", "body": "self"}])
            if endpoint.endswith("/pulls/1473/comments"):
                return json.dumps([{"user": {"login": "hyg1997", "type": "User"}, "body": "inline a"},
                                   {"user": {"login": "hyg1997", "type": "User"}, "body": "inline b"},
                                   {"user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "bot"}])
            if endpoint.endswith("/issues/1473/comments"):
                return json.dumps([{"user": {"login": "iam-abbas", "type": "User"}, "body": "conversation"}])
            raise AssertionError(args)
        got = mr.gh_fields("Instillai-Culture/instill-app-api", "1473", run)
        self.assertEqual(got["human_review_comments"], "4")
        self.assertEqual(got["human_approvals"], "1")


class Fetchers(unittest.TestCase):
    def test_no_token_means_no_fetcher(self):
        self.assertIsNone(mr.jira_fetcher({"ATLASSIAN_SITE": "instill.atlassian.net"}))
        self.assertIsNone(mr.sentry_fetcher({}))
        self.assertIsNotNone(mr.jira_fetcher({"ATLASSIAN_EMAIL": "a@b", "ATLASSIAN_API_TOKEN": "t", "ATLASSIAN_SITE": "x.atlassian.net"}))
        self.assertIsNotNone(mr.sentry_fetcher({"SENTRY_AUTH_TOKEN": "t"}))

    def test_dump_fetcher_maps_a_path_to_a_file_and_a_missing_file_is_unreachable(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "jira"))
            with open(os.path.join(d, "jira", "issue__IT-2263.json"), "w") as f:
                json.dump({"key": "IT-2263"}, f)
            fetch = mr.dump_fetcher(d, "jira")
            self.assertEqual(fetch("issue/IT-2263", {"expand": "changelog"}), {"key": "IT-2263"})
            with self.assertRaises(mr.Unreachable):
                fetch("issue/IT-2264", {"expand": "changelog"})
            self.assertEqual(mr.dump_name("projects/instillai/instill-app-api/issues/"), "projects__instillai__instill-app-api__issues.json")
            self.assertEqual(mr.dump_name("issues/123/events/latest/"), "issues__123__events__latest.json")


class FakeSources:
    """Stands in for mr.Sources: answers per row from dicts, None meaning unreachable or not applicable."""

    def __init__(self, review=None, bounces=None, incidents=None, unreachable=None):
        self._review, self._bounces, self._incidents = review or {}, bounces or {}, incidents or {}
        self.unreachable = dict(unreachable or {})
        self.asked = []

    def review(self, row):
        self.asked.append(("review", row["pr"]))
        return self._review.get(row["pr"])

    def bounces(self, row):
        self.asked.append(("bounces", row["ticket"]))
        return self._bounces.get(row["ticket"])

    def incidents(self, row):
        self.asked.append(("incidents", row["pr"]))
        return self._incidents.get(row["pr"])


class OutcomesPass(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.d, ".claude"))
        self.path = os.path.join(self.d, ".claude", "metrics.csv")
        with open(self.path, "w") as f:
            f.write("\n".join([HEADER_OLD, ROW_OLD, ROW_NEW, ROW_NOKEY]) + "\n")

    def run_pass(self, sources, since="2026-10-27", dry=False):
        buf = io.StringIO()
        with redirect_stdout(buf):
            mr.outcomes(self.d, since, sources, dry)
        with open(self.path) as f:
            return buf.getvalue(), list(csv.DictReader(f))

    def test_adds_the_column_fills_the_three_cells_and_leaves_every_other_cell_as_read(self):
        with open(self.path) as f:
            before = list(csv.DictReader(f))
        out, rows = self.run_pass(FakeSources(review={"1462": "0", "1464": "0"}, bounces={"IT-2263/IT-2264": "0"}, incidents={"1462": "0", "1464": "0"}))
        with open(self.path) as f:
            self.assertEqual(f.readline().strip(), HEADER_OLD.replace("qa_bounces,", "qa_bounces,prod_incidents,"))
        new = rows[1]
        self.assertEqual((new["qa_bounces"], new["human_review_comments"], new["prod_incidents"]), ("0", "0", "0"))
        for col in before[1]:
            if col not in ("qa_bounces", "human_review_comments", "prod_incidents"):
                self.assertEqual(new[col], before[1][col], col)
        self.assertEqual(rows[2]["qa_bounces"], "")  # no key: not asked, stays blank
        self.assertEqual(rows[2]["prod_incidents"], "0")

    def test_rows_before_since_are_written_back_untouched_with_a_blank_new_cell(self):
        self.run_pass(FakeSources(review={"1453": "9"}, bounces={"IT-2254 (readiness)": "9"}, incidents={"1453": "9"}))
        with open(self.path) as f:
            text = f.read().splitlines()
        self.assertEqual(text[1], ROW_OLD.replace(",0,1,1,0,0,,", ",0,1,,1,0,0,,", 1))
        self.assertEqual(next(csv.DictReader(text))["qa_bounces"], "1")

    def test_an_unreachable_source_leaves_the_cell_as_it_was_and_is_named_in_the_summary(self):
        with open(self.path, "w") as f:
            f.write("\n".join([HEADER_OLD, ROW_NEW.replace(",0,,1,0,0,", ",0,2,1,7,0,", 1)]) + "\n")
        src = FakeSources(review={"1462": "0"}, unreachable={"Jira": "no ATLASSIAN_API_TOKEN", "Sentry": "no SENTRY_AUTH_TOKEN"})
        out, rows = self.run_pass(src)
        self.assertEqual(rows[0]["qa_bounces"], "2")
        self.assertEqual(rows[0]["prod_incidents"], "")
        self.assertEqual(rows[0]["human_review_comments"], "0")
        self.assertIn("Jira unreachable (no ATLASSIAN_API_TOKEN)", out)
        self.assertIn("Sentry unreachable (no SENTRY_AUTH_TOKEN)", out)
        self.assertNotIn("qa_bounces=0", out)

    def test_dry_run_prints_the_cells_and_writes_nothing(self):
        with open(self.path) as f:
            before = f.read()
        out, _ = self.run_pass(FakeSources(review={"1462": "0"}, bounces={"IT-2263/IT-2264": "1"}, incidents={"1462": "0"}), dry=True)
        with open(self.path) as f:
            self.assertEqual(f.read(), before)
        self.assertIn("IT-2263/IT-2264", out)
        self.assertIn("qa_bounces=1", out)

    def test_a_row_without_a_pr_asks_nothing_of_github_or_sentry(self):
        with open(self.path, "w") as f:
            f.write("\n".join([HEADER_OLD, ROW_NEW.replace(",1462,MERGED,", ",,,", 1)]) + "\n")
        src = FakeSources()
        self.run_pass(src)
        self.assertNotIn(("review", ""), src.asked)
        self.assertNotIn(("incidents", ""), src.asked)

    def test_build_row_carries_the_new_column(self):
        self.assertIn("prod_incidents", mr.COLUMNS)
        self.assertEqual(mr.COLUMNS.index("prod_incidents"), mr.COLUMNS.index("qa_bounces") + 1)
        self.assertEqual(mr.COLUMNS[-1], "note")


class SourcesRules(unittest.TestCase):
    """mr.Sources wires the rules to the fetchers: blank (None) when a source is missing or the row is not ready."""

    def test_bounces_sums_the_keys_is_blank_without_a_key_and_none_without_jira(self):
        def fetch(path, params=None):
            key = path.split("/")[1]
            when = "2026-10-30T02:00:00.000-0700"
            n = {"IT-2263": 1, "IT-2264": 2}[key]
            return {"changelog": {"total": n, "histories": [history(when, "In QA", "Ready for Dev")] * n}}
        s = mr.Sources("/r", "o/r", jira_fetch=fetch, sentry_fetch=None, run=lambda a, cwd=None: "")
        self.assertEqual(s.bounces({"ticket": "IT-2263/IT-2264", "pr_opened_utc": "2026-10-27T15:17Z"}), "3")
        self.assertEqual(s.bounces({"ticket": "zero-red-unit-suite", "pr_opened_utc": "2026-10-27T18:06Z"}), "")  # no key: blank, not kept
        s2 = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=None, run=lambda a, cwd=None: "")
        self.assertIsNone(s2.bounces({"ticket": "IT-2263", "pr_opened_utc": "2026-10-27T15:17Z"}))
        self.assertEqual(s2.bounces({"ticket": "zero-red-unit-suite", "pr_opened_utc": "2026-10-27T18:06Z"}), "")
        self.assertIn("Jira", s2.unreachable)
        self.assertNotIn("Jira", s.unreachable)

    def test_incidents_is_none_until_the_pr_is_on_beta_and_none_without_sentry(self):
        def run(args, cwd=None):
            if args[:3] == ["gh", "pr", "view"]:
                return json.dumps({"state": "MERGED", "mergeCommit": {"oid": "m1"}, "files": [{"path": "app/x.py"}], "mergedAt": "2026-11-02T15:29:37Z"})
            if args[3] == "log":
                return ""
            return ""
        s = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=lambda p, q=None: [], run=run)
        self.assertIsNone(s.incidents({"pr": "1473", "pr_state": "MERGED", "ticket": "x"}))
        self.assertNotIn("Sentry", s.unreachable)
        s2 = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=None, run=run)
        self.assertIsNone(s2.incidents({"pr": "1473", "pr_state": "MERGED", "ticket": "x"}))
        self.assertIn("Sentry", s2.unreachable)

    def test_incidents_counts_once_the_pr_is_on_beta(self):
        def run(args, cwd=None):
            if args[:3] == ["gh", "pr", "view"]:
                return json.dumps({"state": "MERGED", "mergeCommit": {"oid": "m1"}, "files": [{"path": "app/x.py"}], "mergedAt": "2026-10-28T19:45:46Z"})
            if args[3] == "log":
                return "bbb 2026-10-30T11:44:11+05:30\n"
            if args[3] in ("merge-base", "rev-parse"):
                return "m1\n"
            return ""

        def fetch(path, params=None):
            if path.endswith("/issues/"):
                return [issue(9, "INSTILL-APP-API-ZZ", "2026-10-31T00:00:00Z")] if "instill-app-api/" in path else []
            if path.endswith("/events/latest/"):
                return event("/srv/app/x.py")
            return []
        s = mr.Sources("/r", "Instillai-Culture/instill-app-api", jira_fetch=None, sentry_fetch=fetch, run=run)
        self.assertEqual(s.incidents({"pr": "1462", "pr_state": "MERGED", "ticket": "IT-2263"}), "1")
        self.assertEqual(s.incident_ids["1462"], ["INSTILL-APP-API-ZZ"])

    def test_projects_follow_the_repo(self):
        self.assertEqual(mr.sentry_projects_for("Instillai-Culture/instill-app-api"), ["instill-app-api", "instill-app-api-worker"])
        self.assertEqual(mr.sentry_projects_for("Instillai-Culture/instill-app-web-beta"), ["instill-app-web"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
