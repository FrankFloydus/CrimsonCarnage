"""Independent tiny multi-objective examples for sampled build frontiers."""
import unittest

import numpy as np

import offense_analysis as analysis


class OffensiveAnalysisTests(unittest.TestCase):
    def test_dominance_and_specialization(self):
        scores = [[1, 1], [2, 2], [3, .5], [.5, 3]]
        np.testing.assert_array_equal(analysis.nondominated(scores), [False, True, True, True])

    def test_equal_profiles_share_frontier(self):
        np.testing.assert_array_equal(analysis.nondominated([[2, 2], [2, 2], [1, 1]]), [True, True, False])


if __name__ == "__main__":
    unittest.main()
