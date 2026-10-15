import tempfile
import unittest
from pathlib import Path

import fitz

from analyze_pdfs import MAX_PARTITIONS, analyze_bytes, partition_prefixes


def make_pdf(pages: int, encrypt: bool = False, user_pw: str = "") -> bytes:
    doc = fitz.open()
    for _ in range(pages):
        doc.new_page().insert_text((72, 72), "hello")
    doc.set_metadata({"title": "T", "author": "A"})
    if encrypt:
        return doc.tobytes(
            encryption=fitz.PDF_ENCRYPT_AES_256, user_pw=user_pw, owner_pw="owner"
        )
    return doc.tobytes()


class AnalyzeBytesTests(unittest.TestCase):
    def test_valid_pdf(self):
        data = make_pdf(3)
        row = analyze_bytes("a.pdf", data)
        self.assertEqual(row["page_count"], 3)
        self.assertEqual(row["size_bytes"], len(data))
        self.assertEqual(row["title"], "T")
        self.assertFalse(row["encrypted"])
        self.assertIsNone(row["error"])
        self.assertTrue(row["pdf_version"].startswith("1."))

    def test_corrupt_file_reports_error(self):
        row = analyze_bytes("bad.pdf", b"not a pdf")
        self.assertIsNone(row["page_count"])
        self.assertTrue(row["error"])

    def test_encrypted_with_empty_user_password(self):
        row = analyze_bytes("enc.pdf", make_pdf(2, encrypt=True))
        self.assertEqual(row["page_count"], 2)
        self.assertTrue(row["encrypted"])

    def test_password_required(self):
        row = analyze_bytes("locked.pdf", make_pdf(2, encrypt=True, user_pw="secret"))
        self.assertIsNone(row["page_count"])
        self.assertTrue(row["encrypted"])
        self.assertEqual(row["error"], "encrypted: password required")


class PartitionTests(unittest.TestCase):
    def test_prefixes_cover_every_name_exactly_once(self):
        for partitions in (1, 7, 50, MAX_PARTITIONS):
            owned = [p for i in range(partitions) for p in partition_prefixes(i, partitions)]
            self.assertEqual(len(owned), MAX_PARTITIONS)
            self.assertEqual(len(set(owned)), MAX_PARTITIONS)

    def test_generated_names_match_a_prefix(self):
        name = "doc_0f3a9b2c4d5e.pdf"
        owners = [i for i in range(50) if any(name.startswith(p) for p in partition_prefixes(i, 50))]
        self.assertEqual(len(owners), 1)


if __name__ == "__main__":
    unittest.main()
