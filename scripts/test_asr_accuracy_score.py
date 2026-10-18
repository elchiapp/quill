import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("asr_score", Path(__file__).with_name("asr-accuracy-score.py"))
asr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asr)


class AccuracyScoreTests(unittest.TestCase):
    def test_case_and_punctuation_do_not_create_errors(self):
        self.assertEqual(asr.score("Hello, world!", "hello world", "en_us")["edits"], 0)

    def test_integer_formats_are_scored_both_ways(self):
        self.assertEqual(asr.score("ten", "10.", "en_us", True)["wer"], 0)
        self.assertEqual(asr.score("venticinque", "25", "it_it", True)["wer"], 0)
        self.assertEqual(asr.score("ten", "10", "en_us", False)["wer"], 1)

    def test_accents_and_meaningful_words_are_not_erased(self):
        self.assertEqual(asr.score("è", "e", "it_it", True)["substitutions"], 1)
        self.assertGreater(asr.score("four point two", "4.2", "en_us", True)["edits"], 0)

    def test_all_edit_types_and_corpus_weighting(self):
        substitution = asr.score("one two", "one three", "en_us")
        deletion = asr.score("one two three", "one two", "en_us")
        insertion = asr.score("one", "one two", "en_us")
        self.assertEqual(substitution["substitutions"], 1)
        self.assertEqual(deletion["deletions"], 1)
        self.assertEqual(insertion["insertions"], 1)
        self.assertEqual(asr.totals([substitution, deletion, insertion])["wer"], 0.5)

    def test_silence_counts_hallucinated_words_without_fake_wer(self):
        result = asr.score("", "hello world", "none", True)
        self.assertIsNone(result["wer"])
        self.assertEqual(result["insertions"], 2)


if __name__ == "__main__":
    unittest.main()
