import importlib.util
import sys
from pathlib import Path
from unittest import TestCase, main
from unittest.mock import patch

SCRIPTS = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "icbc_workflow.py"
SPEC = importlib.util.spec_from_file_location("icbc_workflow", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class IcbcWorkflowTest(TestCase):
    def test_conversion_happens_before_reconciliation_and_passes_xlsx(self):
        events = []

        def convert(pdf, excel, *, overwrite):
            events.append(("convert", pdf, excel, overwrite))
            return [object()]

        def reconcile(args):
            events.append(("reconcile", args))
            return 0

        with (
            patch.object(MODULE, "convert_pdf_to_excel", side_effect=convert),
            patch.object(MODULE, "reconcile_main", side_effect=reconcile),
        ):
            result = MODULE.main(
                [
                    "input.pdf",
                    "--excel-output",
                    "output.xlsx",
                    "--username",
                    "user",
                ]
            )

        self.assertEqual(result, 0)
        self.assertEqual([event[0] for event in events], ["convert", "reconcile"])
        self.assertEqual(events[1][1][0], "output.xlsx")

    def test_without_username_stops_after_conversion(self):
        with (
            patch.object(MODULE, "convert_pdf_to_excel", return_value=[object()]),
            patch.object(MODULE, "reconcile_main") as reconcile,
        ):
            result = MODULE.main(["input.pdf", "--excel-output", "output.xlsx"])
        self.assertEqual(result, 0)
        reconcile.assert_not_called()


if __name__ == "__main__":
    main()
