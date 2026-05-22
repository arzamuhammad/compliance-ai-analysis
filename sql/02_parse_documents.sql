-- ============================================================================
-- 02_parse_documents.sql
-- STEP 2: REGULASI (PDF/DOCX) → TEKS TERSTRUKTUR (tabel REGULATIONS)
-- ============================================================================
--
-- FUNGSI / TUJUAN:
--   Mengubah dokumen regulasi mentah (PDF / DOCX) menjadi data
--   TERSTRUKTUR yang bisa dibaca AI di tahap berikutnya. Script ini
--   menjawab pertanyaan: "Bagaimana caranya supaya AI bisa MEMBACA
--   pasal-pasal di dokumen UU PDP / Peraturan BI / kebijakan internal?"
--
--   Output utamanya adalah tabel COMPLIANCE_DOCS.REGULATIONS — satu
--   baris per pasal — yang nantinya dipakai oleh script 04 / 05 sebagai
--   "buku peraturan" untuk auditor AI.
--
-- INPUT:
--   - File PDF / DOCX di internal stage @PDF_STAGE (atau DOCS_STAGE)
--     Contoh:
--       * Peraturan_Perlindungan_Data_Perbankan.pdf  (UU PDP)
--       * Peraturan_BI_No_6-8-PBI-2004.pdf, PADG_082024.pdf
--       * Bank_ABC_SKNBI_Kebijakan_Khusus_2022.docx
--       * Juklak_BI-RTGS_Revisi.docx
--   - Stage dengan ENCRYPTION = SNOWFLAKE_SSE & DIRECTORY = ENABLED
--
-- PROSES (3 langkah berurutan):
--   1. PARSE_DOCUMENT
--        SNOWFLAKE.CORTEX.PARSE_DOCUMENT(@stage, 'file.pdf',
--                                        {'mode': 'LAYOUT'})
--        → membaca PDF/DOCX dan mengekstrak teks mentah (raw content)
--        → output JSON dengan field :content
--
--   2. CORTEX.COMPLETE (LLM Extraction)
--        Cortex LLM (claude-4-sonnet) menerima teks raw lalu MEMECAH
--        dokumen menjadi pasal-pasal terstruktur dalam format JSON
--        array dengan field:
--          - reg_id            : ID unik (REG-001, REG-002, ...)
--          - regulation_name   : nama UU / peraturan
--          - pasal             : nomor pasal / section
--          - category          : DATA_MASKING / ACCESS_CONTROL /
--                                ENCRYPTION / AUDIT_TRAIL /
--                                DATA_RETENTION / NETWORK_SECURITY /
--                                KYC_AML / dll.
--          - title             : judul singkat
--          - severity          : CRITICAL / HIGH / MEDIUM
--          - content           : isi paragraf lengkap pasal
--
--   3. LATERAL FLATTEN
--        Pecah JSON array → satu baris per pasal → INSERT ke tabel
--        COMPLIANCE_DOCS.REGULATIONS
--
-- OUTPUT:
--   - COMPLIANCE_DOCS.REGULATIONS                   (tabel utama, ~12
--                                                    pasal UU PDP, dst.)
--   - COMPLIANCE_DOCS.SP_EXTRACT_REGULATIONS_FROM_PDF (versi reusable
--                                                    sebagai stored
--                                                    procedure)
--   - COMPLIANCE_DOCS.REGULATION_SEARCH             (Cortex Search
--                                                    Service untuk RAG
--                                                    semantic search
--                                                    atas pasal-pasal)
--
-- DEPENDENCY:
--   - Database COMPLIANCE_AI_DEMO sudah dibuat
--   - Schema COMPLIANCE_DOCS sudah dibuat
--   - Stage PDF_STAGE / DOCS_STAGE sudah dibuat & file sudah di-PUT
--   - Warehouse GEN2_SMALL untuk eksekusi Cortex
--   - Cortex enabled di region akun (claude-4-sonnet tersedia)
--
-- POSISI DI PIPELINE:
--   01_data_setup → [02_parse_documents] → 03_ai_classification →
--   04_gap_analysis → 05_refresh_stored_procedures
--
-- HUBUNGAN DENGAN SCRIPT LAIN:
--   - Output script ini (REGULATIONS.CONTENT) dibaca oleh AI di
--     script 04 / 05. Itu sebabnya script 04 disebut "Full AI-Driven":
--     AI BENAR-BENAR MEMBACA isi pasal hasil parsing di sini, BUKAN
--     hardcoded mapping.
--   - Cortex Search Service di akhir script ini juga bisa dipakai
--     oleh dashboard Streamlit / Cortex Agent untuk fitur tanya-jawab
--     regulasi (RAG).
--
-- CATATAN PENTING:
--   - PDF dengan layout kompleks (tabel, multi-kolom) ditangani lebih
--     baik dengan mode 'LAYOUT'. Untuk dokumen text-heavy biasa, mode
--     'OCR' juga tersedia.
--   - DOCX harus di-PUT dengan AUTO_COMPRESS=FALSE supaya
--     PARSE_DOCUMENT bisa membacanya.
--   - Untuk multi-source compliance (UU PDP + Kebijakan Khusus + BI),
--     versi production di script 05 menambahkan kolom REGULATION_SOURCE
--     ke tabel REGULATIONS untuk membedakan dari mana asal pasal.
--   - Kalau PDF besar (>200 halaman), pertimbangkan untuk chunk dulu
--     supaya tidak melebihi context window LLM.
-- ============================================================================
-- STEP 1: SET CONTEXT
-- ============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE COMPLIANCE_AI_DEMO;
USE WAREHOUSE GEN2_SMALL;

-- ============================================================================
-- STEP 2: AUTOMATED PDF EXTRACTION using Snowflake AI
-- Feature: PARSE_DOCUMENT + CORTEX.COMPLETE + FLATTEN
-- ============================================================================
-- Alih-alih manual INSERT, kita gunakan Snowflake AI untuk:
--   1. Membaca PDF regulasi secara otomatis (PARSE_DOCUMENT)
--   2. Mengekstrak data terstruktur menggunakan LLM (CORTEX.COMPLETE)
--   3. Meng-flatten JSON hasil LLM ke tabel (LATERAL FLATTEN)
-- ============================================================================

-- 2a. Upload PDF ke stage (jika belum)
-- PUT file:///path/to/Peraturan_Perlindungan_Data_Perbankan.pdf @COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.PDF_STAGE AUTO_COMPRESS=FALSE;

-- 2b. Verifikasi file di stage
LIST @COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.PDF_STAGE;

-- 2c. PARSE_DOCUMENT: AI membaca dan mengekstrak teks dari PDF
--     Feature: SNOWFLAKE.CORTEX.PARSE_DOCUMENT()
--     Syntax: PARSE_DOCUMENT(@stage, 'filename', {'mode': 'LAYOUT'})
CREATE OR REPLACE TEMPORARY TABLE _tmp_parsed_pdf AS
SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
    @COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.PDF_STAGE, 
    'Peraturan_Perlindungan_Data_Perbankan.pdf',
    {'mode': 'LAYOUT'}
) AS RAW_DOCUMENT;

-- Lihat hasil parsing (preview 500 karakter pertama)
SELECT LEFT(RAW_DOCUMENT:content::VARCHAR, 500) AS PDF_TEXT_PREVIEW FROM _tmp_parsed_pdf;

-- 2d. CORTEX.COMPLETE: LLM mengekstrak regulasi terstruktur dari teks PDF
--     Feature: SNOWFLAKE.CORTEX.COMPLETE() dengan claude-3-5-sonnet
CREATE OR REPLACE TEMPORARY TABLE _tmp_extracted_regs AS
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'claude-4-sonnet',
    'Kamu adalah parser dokumen regulasi. Dari teks dokumen berikut, ekstrak SEMUA regulasi menjadi JSON array.

Untuk setiap regulasi, ekstrak field berikut:
- reg_id: ID regulasi (contoh: REG-001)
- regulation_name: Nama regulasi/UU
- pasal: Pasal/Section
- category: Kategori (DATA_MASKING, ACCESS_CONTROL, DATA_CLASSIFICATION, AUDIT_TRAIL, DATA_RETENTION, ENCRYPTION, NETWORK_SECURITY)
- title: Judul singkat regulasi
- severity: Tingkat keparahan (CRITICAL, HIGH, atau MEDIUM)
- content: Isi lengkap paragraf penjelasan regulasi

PENTING: Kembalikan HANYA valid JSON array, tanpa markdown, tanpa backtick, tanpa penjelasan.
Format: [{"reg_id":"...","regulation_name":"...","pasal":"...","category":"...","title":"...","severity":"...","content":"..."},...]

TEKS DOKUMEN:
' || (SELECT RAW_DOCUMENT:content::VARCHAR FROM _tmp_parsed_pdf)
) AS LLM_RESPONSE;

-- Preview hasil LLM extraction
SELECT LEFT(LLM_RESPONSE, 300) AS LLM_PREVIEW FROM _tmp_extracted_regs;

-- 2e. FLATTEN: Parse JSON array -> INSERT ke tabel REGULATIONS
CREATE OR REPLACE TABLE COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATIONS AS
SELECT 
    f.value:reg_id::VARCHAR AS REG_ID,
    f.value:regulation_name::VARCHAR AS REGULATION_NAME,
    f.value:pasal::VARCHAR AS PASAL,
    f.value:category::VARCHAR AS CATEGORY,
    f.value:title::VARCHAR AS TITLE,
    f.value:severity::VARCHAR AS SEVERITY,
    f.value:content::VARCHAR AS CONTENT
FROM _tmp_extracted_regs,
    LATERAL FLATTEN(input => PARSE_JSON(LLM_RESPONSE)) f
ORDER BY REG_ID;

-- Cleanup temp tables
DROP TABLE IF EXISTS _tmp_parsed_pdf;
DROP TABLE IF EXISTS _tmp_extracted_regs;

-- Verify: 12 regulasi berhasil diekstrak otomatis dari PDF!
SELECT REG_ID, REGULATION_NAME, PASAL, CATEGORY, SEVERITY, LEFT(CONTENT, 80) AS CONTENT_PREVIEW
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATIONS 
ORDER BY REG_ID;

-- ============================================================================
-- STEP 2-ALT: STORED PROCEDURE (opsional - reusable pipeline)
-- Bungkus seluruh flow di atas dalam stored procedure
-- ============================================================================
CREATE OR REPLACE PROCEDURE COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.SP_EXTRACT_REGULATIONS_FROM_PDF(
    PDF_FILENAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    -- Step 1: Parse PDF menggunakan PARSE_DOCUMENT
    CREATE OR REPLACE TEMPORARY TABLE _tmp_parsed_pdf AS
    SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
        @COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.PDF_STAGE, 
        :PDF_FILENAME,
        {'mode': 'LAYOUT'}
    ) AS RAW_DOCUMENT;

    -- Step 2: LLM extraction -> structured JSON
    CREATE OR REPLACE TEMPORARY TABLE _tmp_extracted_regs AS
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
        'claude-4-sonnet',
        'Kamu adalah parser dokumen regulasi. Dari teks dokumen berikut, ekstrak SEMUA regulasi menjadi JSON array.

Untuk setiap regulasi, ekstrak field berikut:
- reg_id: ID regulasi (contoh: REG-001)
- regulation_name: Nama regulasi/UU
- pasal: Pasal/Section
- category: Kategori (DATA_MASKING, ACCESS_CONTROL, DATA_CLASSIFICATION, AUDIT_TRAIL, DATA_RETENTION, ENCRYPTION, NETWORK_SECURITY)
- title: Judul singkat regulasi
- severity: Tingkat keparahan (CRITICAL, HIGH, atau MEDIUM)
- content: Isi lengkap paragraf penjelasan regulasi

PENTING: Kembalikan HANYA valid JSON array, tanpa markdown, tanpa backtick, tanpa penjelasan.
Format: [{"reg_id":"...","regulation_name":"...","pasal":"...","category":"...","title":"...","severity":"...","content":"..."},...]

TEKS DOKUMEN:
' || (SELECT RAW_DOCUMENT:content::VARCHAR FROM _tmp_parsed_pdf)
    ) AS LLM_RESPONSE;

    -- Step 3: Flatten JSON -> INSERT ke tabel
    CREATE OR REPLACE TABLE COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATIONS AS
    SELECT 
        f.value:reg_id::VARCHAR AS REG_ID,
        f.value:regulation_name::VARCHAR AS REGULATION_NAME,
        f.value:pasal::VARCHAR AS PASAL,
        f.value:category::VARCHAR AS CATEGORY,
        f.value:title::VARCHAR AS TITLE,
        f.value:severity::VARCHAR AS SEVERITY,
        f.value:content::VARCHAR AS CONTENT
    FROM _tmp_extracted_regs,
        LATERAL FLATTEN(input => PARSE_JSON(LLM_RESPONSE)) f
    ORDER BY REG_ID;

    DROP TABLE IF EXISTS _tmp_parsed_pdf;
    DROP TABLE IF EXISTS _tmp_extracted_regs;

    LET row_count INTEGER := (SELECT COUNT(*) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATIONS);
    RETURN 'Successfully extracted ' || :row_count || ' regulations from ' || :PDF_FILENAME;
END;
$$;

-- Penggunaan stored procedure (1 baris untuk seluruh pipeline):
-- CALL COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.SP_EXTRACT_REGULATIONS_FROM_PDF('Peraturan_Perlindungan_Data_Perbankan.pdf');

-- ============================================================================
-- STEP 3: CREATE CORTEX SEARCH SERVICE (RAG untuk Regulasi)
-- Feature: Cortex Search - Semantic search over regulation documents
-- ============================================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATION_SEARCH
    ON CONTENT
    ATTRIBUTES REGULATION_NAME, PASAL, CATEGORY, TITLE, SEVERITY
    WAREHOUSE = GEN2_SMALL
    TARGET_LAG = '1 hour'
AS (
    SELECT 
        REG_ID, REGULATION_NAME, PASAL, CATEGORY, TITLE, SEVERITY, CONTENT
    FROM COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATIONS
);

-- Test Cortex Search
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATION_SEARCH',
    'perlindungan data pribadi masking',
    {
        'columns': ['REG_ID','TITLE','SEVERITY','CONTENT'],
        'limit': 3
    }
);
