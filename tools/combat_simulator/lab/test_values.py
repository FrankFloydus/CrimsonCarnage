"""Pure presentation helpers; no Tk root, widget construction, or desktop access."""
import math
import unittest

try:
    from .test_helpers import PROJECT_ROOT
except ImportError:
    from test_helpers import PROJECT_ROOT

from tools.combat_simulator.lab import widgets


class PresentationValueTests(unittest.TestCase):
    def test_numeric_input_accepts_real_numbers_and_rejects_nonfinite_or_boolean_values(self):
        self.assertEqual(widgets.finite_number("-12.5"), -12.5)
        self.assertEqual(widgets.finite_number(0), 0)
        self.assertEqual(widgets.finite_number("1e100"), 1e100)
        for value in [True, False, None, "not a number", "NaN", "inf", -math.inf]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                widgets.finite_number(value, "Test stat")

    def test_accuracy_curves_allow_experiments_without_silently_clamping_invalid_points(self):
        self.assertEqual(widgets.validated_curve([.8, .2, .9, 0, 1]), [.8, .2, .9, 0, 1])
        for points in [[], [0] * 61, [-.01], [1.01], [math.nan], [True], "0.8,0.5"]:
            with self.subTest(points=points), self.assertRaises(ValueError):
                widgets.validated_curve(points)

    def test_missing_kill_times_are_displayed_as_missing_not_as_horizon_or_zero(self):
        for kind in ["number", "seconds", "percent", "integer"]:
            self.assertEqual(widgets.format_result_value(None, kind), "\u2014")
        self.assertEqual(widgets.format_result_value(0, "seconds"), "0.000s")
        self.assertEqual(widgets.format_result_value(.9, "percent"), "90.00%")
        self.assertEqual(widgets.format_result_value(1000000, "integer"), "1,000,000")
        self.assertEqual(widgets.format_result_value(math.inf, "seconds"), "\u2014")

    def test_histogram_validation_preserves_real_counts_and_rejects_malformed_external_data(self):
        self.assertEqual(widgets.histogram_bins({"edges": [0, 1, 3], "counts": [5, 2]}),
                         [(0.0, 1.0, 5), (1.0, 3.0, 2)])
        for histogram in [{}, None, {"edges": [0, 1], "counts": []},
                          {"edges": [1, 0], "counts": [2]},
                          {"edges": [0, math.inf], "counts": [2]},
                          {"edges": [0, 1], "counts": [-1]},
                          {"edges": [0, 1], "counts": [.5]},
                          {"edges": [0, 1], "counts": [math.nan]}]:
            with self.subTest(histogram=histogram):
                self.assertEqual(widgets.histogram_bins(histogram), [])


class ResultCatalogueTests(unittest.TestCase):
    def catalogue(self):
        return widgets.ResultCatalogue(widgets.ResultsPanel.COLUMNS)

    def test_upserts_replace_by_index_and_update_aggregate_deltas(self):
        catalogue = self.catalogue()
        first = {"index": 7, "player_name": "First", "trials": 10, "kills": 3, "timeouts": 7}
        self.assertEqual(catalogue.upsert(first), (0, True))
        self.assertEqual(catalogue.upsert({"index": 2, "trials": 20, "kills": 20, "timeouts": 0}), (1, True))
        self.assertEqual(catalogue.totals, {"trials": 30, "kills": 23, "timeouts": 7})
        self.assertEqual(catalogue.upsert({"index": 7, "player_name": "Updated", "trials": 40,
                                          "kills": 20, "timeouts": 20}), (0, False))
        self.assertEqual(len(catalogue.rows), 2)
        self.assertEqual(catalogue.totals, {"trials": 60, "kills": 40, "timeouts": 20})
        self.assertEqual(catalogue.matching_positions("updated"), [0])
        self.assertEqual(catalogue.matching_positions("first"), [])
        with self.assertRaises(ValueError):
            catalogue.upsert([])
        with self.assertRaises(ValueError):
            catalogue.upsert({"index": []})

    def test_cached_filtering_and_formatting_use_unicode_casefold_and_measurement_units(self):
        catalogue = self.catalogue()
        catalogue.upsert({"index": 0, "player_name": "Stra\u00dfe", "enemy_name": "\u708e",
                          "ability_name": "Fireball", "variants": {"Armor": 100},
                          "kill_rate": .9, "ttk_mean": None})
        self.assertEqual(catalogue.matching_positions(" STRASSE "), [0])
        self.assertEqual(catalogue.matching_positions("\u708e"), [0])
        self.assertEqual(catalogue.matching_positions("armor=100"), [0])
        self.assertEqual(catalogue.matching_positions("missing"), [])
        formatted = catalogue.formatted(0)
        self.assertIn("90.00%", formatted)
        ttk_index = [entry[0] for entry in widgets.ResultsPanel.COLUMNS].index("ttk_mean")
        self.assertEqual(formatted[ttk_index], "\u2014")

    def test_numeric_sorting_keeps_missing_kill_times_last_in_both_directions(self):
        catalogue = self.catalogue()
        for index, value in enumerate([None, 1, 10, 2]):
            catalogue.upsert({"index": index, "ttk_mean": value})
        positions = list(range(4))
        self.assertEqual(catalogue.sorted_positions(positions, "ttk_mean"), [1, 3, 2, 0])
        self.assertEqual(catalogue.sorted_positions(positions, "ttk_mean", descending=True), [2, 3, 1, 0])
        self.assertEqual(positions, [0, 1, 2, 3])

    def test_large_catalogue_pagination_and_export_preserve_every_row(self):
        catalogue = self.catalogue()
        row = {"player_name": "Shared", "trials": 10, "kills": 5, "timeouts": 5,
               "analytic": {"assumptions": ["Initial"]}}
        for index in range(10000):
            catalogue.upsert(dict(row, index=index))
        row["analytic"]["assumptions"].append("External mutation")
        self.assertEqual(catalogue.totals, {"trials": 100000, "kills": 50000, "timeouts": 50000})
        positions = catalogue.matching_positions("shared")
        page, current, total = widgets.result_page(positions, 1000)
        self.assertEqual((len(page), current, total), (200, 49, 50))
        self.assertEqual(page, list(range(9800, 10000)))
        exported = catalogue.export_rows()
        self.assertEqual(len(exported), 10000)
        self.assertEqual(exported[0]["analytic"]["assumptions"], ["Initial"])
        exported[0]["analytic"]["assumptions"].append("Export mutation")
        self.assertEqual(catalogue.export_rows()[0]["analytic"]["assumptions"], ["Initial"])
        catalogue.clear()
        self.assertEqual(catalogue.rows, [])
        self.assertEqual(catalogue.totals, {"trials": 0, "kills": 0, "timeouts": 0})
        self.assertEqual(catalogue.matching_positions(""), [])

    def test_page_bounds_and_empty_result_sets(self):
        self.assertEqual(widgets.result_page([], 50), ([], 0, 1))
        self.assertEqual(widgets.result_page(list(range(5)), -3, page_size=2), ([0, 1], 0, 3))
        self.assertEqual(widgets.result_page(list(range(5)), 99, page_size=2), ([4], 2, 3))
        with self.assertRaises(ValueError):
            widgets.result_page([], 0, page_size=0)


if __name__ == "__main__":
    unittest.main()
