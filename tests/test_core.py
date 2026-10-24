import importlib.util
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("vpsprobe_server", ROOT / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class CoreTests(unittest.TestCase):
    def test_cycle_before_and_after_billing_day(self):
        before = int(datetime(2026, 10, 14, tzinfo=timezone.utc).timestamp())
        after = int(datetime(2026, 10, 15, tzinfo=timezone.utc).timestamp())
        self.assertEqual(server.cycle_key(before, 15), "2026-09-15")
        self.assertEqual(server.cycle_key(after, 15), "2026-10-15")

    def test_database_initialization(self):
        original = server.DB_PATH
        try:
            with tempfile.TemporaryDirectory() as directory:
                server.DB_PATH = Path(directory) / "test.db"
                server.init_db()
                with server.conn() as db:
                    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                self.assertTrue({"servers", "samples", "events", "enrollments"}.issubset(tables))
        finally:
            server.DB_PATH = original


if __name__ == "__main__":
    unittest.main()
