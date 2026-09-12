import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / 'dev'))
from adjutant_exploration import unobserved_spans


class ExplorationObservationTests(unittest.TestCase):
    def test_spans_preserve_edge_cells_and_gaps(self):
        cells = {(0, 49), (1, 49), (3, 49), (49, 0), (49, 1)}
        reconstructed = set()
        for z, start, end in unobserved_spans(cells):
            reconstructed.update((x, int(z-.5)) for x in range(int(start-.5), int(end-.5)+1))
        self.assertEqual(reconstructed, cells)

    def test_full_coverage_has_no_remaining_spans(self):
        self.assertEqual(unobserved_spans(set()), [])
