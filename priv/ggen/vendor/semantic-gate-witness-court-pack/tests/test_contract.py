import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
COURT = ROOT / "templates" / "semantic-gate-witness-court.py.tera"


def write_consumer(root: Path, *, require_fail: bool = False):
    (root / "gates").mkdir(parents=True)
    (root / "witnesses" / "pass").mkdir(parents=True)
    (root / "witnesses" / "fail").mkdir(parents=True)
    (root / "gate-court.toml").write_text('[court]\n' 'schema = "ggen.semantic-gate-witness-court/1"\n' 'case_key = "exact-stem"\n' 'gate_dir = "gates"\n' 'pass_dir = "witnesses/pass"\n' 'fail_dir = "witnesses/fail"\n' 'require_pass = true\n' f'require_fail = {str(require_fail).lower()}\n', encoding="utf-8")
    for key in ("010_alpha", "020_beta"):
        (root / "gates" / f"{key}.rq").write_text("ASK { ?s ?p ?o }\n", encoding="utf-8")
        (root / "witnesses" / "pass" / f"{key}.ttl").write_text("<urn:s> <urn:p> <urn:o> .\n", encoding="utf-8")


def run(root: Path):
    return subprocess.run([sys.executable, str(COURT), str(root)], text=True, capture_output=True, check=False)


class SemanticGateWitnessCourtTests(unittest.TestCase):
    def test_pack_surface_and_identity(self):
        required = ["pack.toml", "ontology.ttl", "ggen.toml", "queries/10-court.rq", "gates/01-court-contract.rq", "templates/semantic-gate-witness-court.py.tera", "templates/semantic-runner.py.tera"]
        for rel in required:
            self.assertTrue((ROOT / rel).is_file(), rel)
        self.assertIn('name = "semantic-gate-witness-court-pack"', (ROOT / "pack.toml").read_text())
        self.assertIn('ggen.semantic-gate-witness-court/1', (ROOT / "ontology.ttl").read_text())
        ontology = (ROOT / "ontology.ttl").read_text()
        self.assertIn('sgwc:CanonicalRunner', ontology)
        self.assertIn('sgwc:template "templates/semantic-runner.py.tera"', ontology)

    # Consumer packs whose runners/semantic_runner.py is a byte-identical
    # projection of templates/semantic-runner.py.tera (mechanism verdict B,
    # v26.9.30 consolidation: the runner resolves gates from its own file
    # location, so a shared cross-pack runner file is structurally impossible
    # without a behavior change; dedup is therefore template + projections).
    CONSUMER_RUNNER_PROJECTIONS = (
        "affidavit-consumer-pack",
        "affidavit-trust-plane-pack",
        "capability-closure-pack",
        "wasi-json-abi-pack",
    )

    def test_consumer_runners_are_byte_identical_projections(self):
        template_bytes = (ROOT / "templates" / "semantic-runner.py.tera").read_bytes()
        checked = 0
        for pack in self.CONSUMER_RUNNER_PROJECTIONS:
            copy = ROOT.parent / pack / "runners" / "semantic_runner.py"
            if not copy.is_file():
                continue  # consumer packs come and go with consolidation waves
            self.assertEqual(
                copy.read_bytes(),
                template_bytes,
                f"{pack}/runners/semantic_runner.py drifted from the kernel runner template",
            )
            checked += 1
        self.assertGreaterEqual(checked, 1)

    def test_complete_positive_matrix_is_alive_and_deterministic(self):
        with tempfile.TemporaryDirectory() as td:
            consumer = Path(td)
            write_consumer(consumer)
            first = run(consumer)
            second = run(consumer)
            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
            self.assertEqual(first.stdout, second.stdout)
            receipt = json.loads(first.stdout)
            self.assertEqual(receipt["standing"], "ALIVE")
            self.assertEqual(receipt["gate_count"], 2)
            self.assertEqual(receipt["pass_witness_count"], 2)
            self.assertEqual([case["key"] for case in receipt["cases"]], ["010_alpha", "020_beta"])

    def test_missing_positive_witness_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            consumer = Path(td)
            write_consumer(consumer)
            (consumer / "witnesses" / "pass" / "020_beta.ttl").unlink()
            proc = run(consumer)
            self.assertEqual(proc.returncode, 1)
            receipt = json.loads(proc.stdout)
            self.assertEqual(receipt["standing"], "REFUSED")
            self.assertIn({"kind": "missing_pass", "keys": ["020_beta"]}, receipt["errors"])

    def test_orphan_witness_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            consumer = Path(td)
            write_consumer(consumer)
            (consumer / "witnesses" / "pass" / "999_orphan.ttl").write_text("<urn:s> <urn:p> <urn:o> .\n")
            proc = run(consumer)
            self.assertEqual(proc.returncode, 1)
            receipt = json.loads(proc.stdout)
            self.assertIn({"kind": "orphan_pass", "keys": ["999_orphan"]}, receipt["errors"])

    def test_required_negative_matrix_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as td:
            consumer = Path(td)
            write_consumer(consumer, require_fail=True)
            proc = run(consumer)
            self.assertEqual(proc.returncode, 1)
            receipt = json.loads(proc.stdout)
            self.assertIn({"kind": "missing_fail", "keys": ["010_alpha", "020_beta"]}, receipt["errors"])


if __name__ == "__main__":
    unittest.main()
