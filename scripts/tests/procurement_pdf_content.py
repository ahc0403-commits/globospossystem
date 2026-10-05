"""Inspect rendered PDF text; requires pypdf in the chosen document runtime."""
import pathlib,sys,re
from pypdf import PdfReader
for directory in sys.argv[1:]:
    files=list(pathlib.Path(directory).glob('*.pdf'))
    assert len(files)==6, f'Expected all KO/EN/VI supplier/PR PDFs in {directory}'
    for file in files:
        reader=PdfReader(file);text=re.sub(r'\s+',' ',' '.join(page.extract_text() for page in reader.pages))
        assert 'Test item 199' in text, f'Last of 200 items omitted: {file.name}'
        assert 'Test note 199' in text, f'Notes omitted: {file.name}'
        assert '2026-10-01' in text and '2026-10-02' in text and '2026-10-03' in text
        assert 'PRIVATE_BANK_TEST' not in text and 'PRIVATE_APPROVAL_TEST' not in text
        assert '987654321.55' not in text, f'Internal price escaped: {file.name}'
        if file.name.startswith('supplier'):
            assert 'VAT' not in text and '15678.90' not in text and '567.89' not in text
        else:
            assert '15678.90' in text and '567.89' in text
            assert all(f'Approved TEST {stage}' in text for stage in ['store','brand','office'])
        print(f'PASS: {pathlib.Path(directory).name}/{file.name}: {len(reader.pages)} pages; 200 lines, dates, notes and audience fields verified')
