#!/usr/bin/env python3
"""Rotation cursor for core-oj-source-daily: which day's metros the next import works.

The importer (starfire-core scripts/oj-source-overture.py --rotate --date D) picks its metros from
business_day_number(D). Left on the calendar, a run that the database IO gate stops before the import
loses that day's metros for a whole wrap of the list. So the workflow keeps a cursor N, the business
day number the next import works, passes the date that maps to N, and moves N forward only after an
import that completed.

  day      print the date for the cursor in FILE (no file: today, UTC)
  advance  write cursor + 1 to FILE
"""
import argparse
import os
import sys
from datetime import date, datetime, timedelta, timezone

MONDAY0 = date(2026, 1, 5)  # same anchor as starfire-core business_day_number


def business_day_number(day: date) -> int:
    days = (day - MONDAY0).days
    return (days // 7) * 5 + min(days % 7, 4)


def day_for_number(n: int) -> date:
    return MONDAY0 + timedelta(days=(n // 5) * 7 + n % 5)


def read_cursor(path: str, today: date) -> int:
    if os.path.exists(path):
        text = open(path).read().strip()
        if not text.isdigit():
            raise ValueError(f"cursor file {path} holds {text!r}, not a business day number")
        return int(text)
    return business_day_number(today)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["day", "advance"])
    p.add_argument("file")
    p.add_argument("--today", help="YYYY-MM-DD, default today UTC (tests)")
    a = p.parse_args(argv)
    today = date.fromisoformat(a.today) if a.today else datetime.now(timezone.utc).date()
    n = read_cursor(a.file, today)
    if a.cmd == "day":
        print(day_for_number(n).isoformat())
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(a.file)), exist_ok=True)
    with open(a.file, "w") as fh:
        fh.write(f"{n + 1}\n")
    print(f"cursor {n} -> {n + 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
