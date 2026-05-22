-- ============================================================================
-- SP_EXTRACT_REGULATIONS_V2 - Chunked extraction with claude-opus-4-7
-- ============================================================================
-- Replaces the single-call extractor in 02_parse_documents.sql for
-- multi-page docs. Splits parsed text into overlapping chunks and runs
-- claude-opus-4-7 per chunk to capture every rule (not just summaries).
--
-- Usage:
--   CALL COMPLIANCE_DOCS.SP_EXTRACT_REGULATIONS_V2(
--     '<file in DOCS_STAGE>', '<UU_PDP|KEBIJAKAN_KHUSUS|BI_REGULATION>',
--     '<full regulation name>', '<REG_ID prefix>',
--     8000, 500, '<APPLIES_TO scope>');
-- ============================================================================
Try 'snow sql --help' for help.
╭─ Error ──────────────────────────────────────────────────────────────────────╮
│ Invalid value for '--format': 'plain' is not one of 'TABLE', 'JSON',         │
│ 'JSON_EXT', 'CSV'.                                                           │
╰──────────────────────────────────────────────────────────────────────────────╯
