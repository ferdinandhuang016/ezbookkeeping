import importlib.util
import sys
from pathlib import Path
from unittest import TestCase, main

SCRIPTS = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "icbc_apply_reconciliation.py"
SPEC = importlib.util.spec_from_file_location("icbc_apply_reconciliation", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class IcbcApplyReconciliationTest(TestCase):
    def test_payload_preserves_transaction_metadata(self):
        row = {
            "id": "1",
            "type": 3,
            "categoryId": "2",
            "time": 100,
            "utcOffset": 480,
            "sourceAccountId": "3",
            "sourceAmount": 270,
            "hideAmount": True,
            "tagIds": ["4"],
            "pictures": [{"id": "5"}],
            "comment": "memo",
            "geoLocation": {"latitude": 1.0, "longitude": 2.0},
        }
        payload = MODULE.payload_from_row(row)
        self.assertEqual(payload["tagIds"], ["4"])
        self.assertEqual(payload["pictureIds"], ["5"])
        self.assertEqual(payload["comment"], "memo")
        self.assertEqual(payload["geoLocation"]["latitude"], 1.0)

    def test_adjust_payload_changes_only_time_and_selected_amount(self):
        row = {
            "id": "1",
            "type": 2,
            "categoryId": "2",
            "time": 100,
            "utcOffset": 480,
            "sourceAccountId": "3",
            "sourceAmount": 700000,
            "hideAmount": False,
            "tagIds": [],
            "comment": "公积金提取",
            "editable": True,
        }
        payload = MODULE.adjust_payload_for_bank(row, 699999, 200, "3")
        self.assertEqual(payload["time"], 200)
        self.assertEqual(payload["sourceAmount"], 699999)
        self.assertEqual(payload["categoryId"], "2")
        self.assertEqual(payload["comment"], "公积金提取")


if __name__ == "__main__":
    main()
