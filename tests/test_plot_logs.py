import csv
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import matplotlib.image as mpimg
import numpy as np

from plot_logs import OUTPUT_NAME, create_plot, fall_spans, load_logs, process_folders


class PlotLogsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.folder = self.root / "session"
        self.folder.mkdir()
        (self.folder / "session.json").write_text(json.dumps({
            "units": {"accelerometer": "m/s^2"},
            "sampling_rate_hz": 30,
        }), encoding="utf-8")
        self.write_rows()

    def write_rows(self, times=(10**18, 10**18 + 100_000_000, 10**18 + 200_000_000)):
        with (self.folder / "motion.csv").open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow([
                "timestamp_ns", "source", "clock_domain", "falling",
                "accelerometer_x", "accelerometer_y", "accelerometer_z",
            ])
            for index, timestamp in enumerate(times):
                writer.writerow([
                    timestamp, "GLASSES", "device", int(index == 1),
                    3, 4, "" if index == 0 else 0,
                ])

    def test_integer_timestamps_missing_values_and_fall_spans(self):
        log, = load_logs(self.folder / "motion.csv")
        np.testing.assert_allclose(log.time, [0, 0.1, 0.2])
        self.assertTrue(np.isnan(log.values["accelerometer_z"][0]))
        self.assertTrue(np.isnan(log.values["gyroscope_x"]).all())
        np.testing.assert_allclose(fall_spans(log), [(0.05, 0.15)])

    def test_reorders_timestamps_with_warning(self):
        self.write_rows((200_000_000, 0, 100_000_000))
        with self.assertLogs("plot_logs", level="WARNING"):
            log, = load_logs(self.folder / "motion.csv")
        np.testing.assert_allclose(log.time, [0, 0.1, 0.2])

    def test_existing_image_skips_reading_and_preserves_output(self):
        output = self.folder / OUTPUT_NAME
        output.write_bytes(b"existing image")
        before = output.stat().st_mtime_ns
        (self.folder / "motion.csv").unlink()
        with patch("plot_logs.create_plot") as create:
            self.assertEqual(process_folders(self.root), 0)
        create.assert_not_called()
        self.assertEqual(output.read_bytes(), b"existing image")
        self.assertEqual(output.stat().st_mtime_ns, before)

    def test_creates_readable_png_and_cleans_temporary_files(self):
        output = self.folder / OUTPUT_NAME
        create_plot(self.folder, output)
        image = mpimg.imread(output)
        self.assertEqual(image.shape[:2], (2100, 2700))
        self.assertGreater(float(image.std()), 0.01)
        self.assertEqual(list(self.folder.glob(".motion_plots-*")), [])

    def test_error_does_not_stop_later_folders(self):
        (self.root / "aaa_broken").mkdir()
        with self.assertLogs("plot_logs", level="ERROR"):
            result = process_folders(self.root)
        self.assertEqual(result, 1)
        self.assertTrue((self.folder / OUTPUT_NAME).is_file())
        self.assertFalse((self.root / "aaa_broken" / OUTPUT_NAME).exists())

    def test_failed_save_does_not_leave_output(self):
        output = self.folder / OUTPUT_NAME
        with patch("matplotlib.figure.Figure.savefig", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                create_plot(self.folder, output)
        self.assertFalse(output.exists())
        self.assertEqual(list(self.folder.glob(".motion_plots-*")), [])

    def test_invalid_timestamp_reports_line(self):
        self.write_rows(("invalid",))
        with self.assertRaisesRegex(ValueError, "riga 2"):
            load_logs(self.folder / "motion.csv")

    def test_single_sample_is_supported(self):
        self.write_rows((10**18,))
        create_plot(self.folder, self.folder / OUTPUT_NAME)
        self.assertTrue((self.folder / OUTPUT_NAME).is_file())


if __name__ == "__main__":
    unittest.main()
