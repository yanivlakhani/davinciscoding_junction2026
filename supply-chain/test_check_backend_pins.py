"""Tests for check_backend_pins.py.

    python3 -m unittest discover -s supply-chain -p 'test_*.py'

The checker exists to notice when the server's code and the pinned files
disagree, so most of these build a small disagreement and make sure it is
reported rather than passed.
"""

import pathlib
import sys
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import check_backend_pins as pins  # noqa: E402

SERVER = textwrap.dedent(
    '''
    import modal

    image = (
        modal.Image.debian_slim(python_version="3.12")
        .uv_pip_install(
            "fastapi[standard]",
            "opencv-python-headless<5",   # 4.x ships the Haar face cascades
            "numpy",
        )
    )
    '''
)
DECLARED = "# comment\nfastapi[standard]\nopencv-python-headless<5\nnumpy\n"
LOCK = textwrap.dedent(
    """
    fastapi==0.163.0 \\
        --hash=sha256:aaaa
        # via -r backend-requirements.in
    numpy==2.5.4 \\
        --hash=sha256:bbbb
    opencv-python-headless==4.14.0.94 \\
        --hash=sha256:cccc
    starlette==1.10.0 \\
        --hash=sha256:dddd
    """
)


class Case(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def run_check(self, server=SERVER, declared=DECLARED, lock=LOCK, mirror=None):
        (self.dir / "fall_server.py").write_text(server)
        (self.dir / "req.in").write_text(declared)
        (self.dir / "req.txt").write_text(lock)
        mirror_path = None
        if mirror is not None:
            mirror_path = self.dir / "mirror.txt"
            mirror_path.write_text(mirror)
        try:
            return pins.check(self.dir / "fall_server.py", self.dir / "req.in", self.dir / "req.txt", mirror_path)
        except pins.Unsupported as error:
            return [], [str(error)]

    def test_agreement_passes_and_reports_each_pin(self):
        report, problems = self.run_check()
        self.assertEqual(problems, [])
        self.assertTrue(any("opencv-python-headless==4.14.0.94" in line for line in report))

    def test_dependency_added_to_the_code_is_caught(self):
        server = SERVER.replace('"numpy",', '"numpy",\n        "requests",')
        _, problems = self.run_check(server=server)
        self.assertTrue(any("'requests' is in" in p and "but not in" in p for p in problems), problems)
        self.assertTrue(any("no pin for requests" in p for p in problems), problems)

    def test_dependency_removed_from_the_code_is_caught(self):
        server = SERVER.replace('"numpy",', "")
        _, problems = self.run_check(server=server)
        self.assertTrue(any("'numpy' is in" in p for p in problems), problems)

    def test_changed_version_constraint_is_caught(self):
        server = SERVER.replace("opencv-python-headless<5", "opencv-python-headless<4.10")
        _, problems = self.run_check(server=server, declared=DECLARED.replace("<5", "<4.10"))
        self.assertTrue(any("does not satisfy <4.10" in p for p in problems), problems)

    def test_constraint_differing_between_code_and_file_is_caught(self):
        _, problems = self.run_check(declared=DECLARED.replace("<5", "<6"))
        self.assertTrue(any("opencv-python-headless<5" in p for p in problems), problems)

    def test_declared_package_missing_from_the_lock_is_caught(self):
        lock = "\n".join(line for line in LOCK.splitlines() if not line.startswith("numpy"))
        _, problems = self.run_check(lock=lock)
        self.assertTrue(any("no pin for numpy" in p for p in problems), problems)

    def test_names_are_compared_the_way_pypi_compares_them(self):
        lock = LOCK.replace("opencv-python-headless==", "OpenCV_Python.Headless==")
        _, problems = self.run_check(lock=lock)
        self.assertEqual(problems, [])

    def test_mirror_copy_must_list_the_same_declarations(self):
        _, ok = self.run_check(mirror="numpy\nopencv-python-headless <5\nfastapi[standard]\n")
        self.assertEqual(ok, [])
        _, problems = self.run_check(mirror="fastapi[standard]\nnumpy\n")
        self.assertTrue(any("opencv-python-headless<5" in p and "mirror.txt" in p for p in problems), problems)

    def test_code_without_an_install_call_is_an_error_not_a_pass(self):
        _, problems = self.run_check(server="import modal\nimage = modal.Image.debian_slim()\n")
        self.assertTrue(any("no uv_pip_install()" in p for p in problems), problems)

    def test_computed_arguments_are_refused_rather_than_skipped(self):
        server = SERVER.replace('"numpy",', "EXTRA,")
        _, problems = self.run_check(server=server)
        self.assertTrue(any("not a plain" in p for p in problems), problems)

    def test_requirements_it_cannot_evaluate_are_refused(self):
        server = SERVER.replace('"numpy",', '"numpy; python_version < \'3.13\'",')
        _, problems = self.run_check(server=server)
        self.assertTrue(any("markers" in p for p in problems), problems)

    def test_version_clauses(self):
        cases = [
            ("4.14.0.94", "<", "5", True),
            ("5.0.0", "<", "5", False),
            ("5.0rc1", "<", "5", False),      # conservative: a 5.0 pre-release is not "<5"
            ("2.5.4", ">=", "2.5", True),
            ("2.5", "==", "2.5.0", True),
            ("2.5.4", "==", "2.5.*", True),
            ("2.6.0", "==", "2.5.*", False),
            ("2.5.4", "!=", "2.5.4", False),
            ("2.5.4", "~=", "2.5", True),
            ("3.0.0", "~=", "2.5", False),
            ("2.5.4", "~=", "2.5.1", True),
            ("2.6.0", "~=", "2.5.1", False),
        ]
        for pinned, op, wanted, expected in cases:
            with self.subTest(f"{pinned} {op} {wanted}"):
                self.assertEqual(pins.satisfies(pinned, op, wanted), expected)

    def test_exit_status(self):
        (self.dir / "fall_server.py").write_text(SERVER)
        (self.dir / "req.in").write_text(DECLARED)
        (self.dir / "req.txt").write_text(LOCK)
        args = ["--source", str(self.dir / "fall_server.py"), "--declared", str(self.dir / "req.in"), "--pins", str(self.dir / "req.txt")]
        self.assertEqual(pins.main(args), 0)
        (self.dir / "req.in").write_text(DECLARED + "requests\n")
        self.assertEqual(pins.main(args), 1)


if __name__ == "__main__":
    unittest.main()
