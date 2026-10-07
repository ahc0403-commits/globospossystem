"""Check extracted output of procurement_document_pdf_test.dart fixtures."""
import pathlib
import re
import sys

from pypdf import PdfReader

directory = pathlib.Path(sys.argv[1])
labels = {
    "ko": ("견적 필요", "산출 대기", "대기", "예상 합계", "승인 일시"),
    "en": ("Quote required", "Calculation pending", "Pending", "Estimated total", "Approval time"),
    "vi": ("Cần báo giá", "Chờ tính toán", "Chờ duyệt", "Tổng dự kiến", "Thời gian duyệt"),
}


def compact(text):
    return re.sub(r"\s+", "", text)


for locale, (quote, calculation, pending, total, approved_at) in labels.items():
    for count in (1, 11, 50):
        file = directory / f"pr-{count}-{locale}.pdf"
        reader = PdfReader(file)
        pages = [compact(page.extract_text()) for page in reader.pages]
        text = "".join(pages)
        assert "2026-10-07" in text and "2026-10-09" in text, file
        assert "1.125" in text and "2.375" in text, file
        assert compact("Nước giải khát không đường chai thủy tinh") in text, file
        assert compact(f"{count}. 원재료") in text, file
        assert "PR-EXAMPLE-20261007" in text, file
        assert compact(total) in pages[-1] and compact(approved_at) in pages[-1], file
        assert compact(pending) in pages[-1], file
        assert f"{count * 13333.32:,.2f}".rstrip("0").rstrip(".") in pages[-1], file
        for index, page in enumerate(reader.pages, 1):
            assert abs(float(page.mediabox.width) - 595.28) < 1, file
            assert abs(float(page.mediabox.height) - 841.89) < 1, file
            assert "PR-EXAMPLE-20261007" in pages[index - 1], file
            assert f"{index}/{len(pages)}" in pages[index - 1], file
        print(f"PASS: {file.name}; {len(pages)} A4 pages, dates, precision, final summary and pending approval")

    file = directory / f"pr-incomplete-{locale}.pdf"
    reader = PdfReader(file)
    text = compact("".join(page.extract_text() for page in reader.pages))
    assert "PR-INCOMPLETE" in text and "Knownestimateitem" in text and "Unpriceditem" in text, file
    assert "12,345.67" in text, file
    assert compact(quote) in text, file
    assert text.count(compact(calculation)) == 3, file
    assert text.replace(compact(calculation), "").count(compact(pending)) == 3, file
    assert "2026-10-07" in text and "2026-10-09" in text, file
    assert "13,333.32" not in text, f"Partial known line must not become a complete total: {file}"
    print(f"PASS: {file.name}; missing price and three incomplete totals; three pending approvals")
