-- =============================================================================
-- 05_refresh_stored_procedures.sql
-- STEP 6: PRODUCTION REFRESH PIPELINE — Idempotent Stored Procedures
-- =============================================================================
--
-- FUNGSI / TUJUAN:
--   Ini adalah versi PRODUCTION dari pipeline AI compliance. Sementara
--   script 03 & 04 adalah skrip manual one-shot untuk men-setup demo,
--   script 05 membungkus seluruh logika AI (klasifikasi + gap analysis)
--   ke dalam STORED PROCEDURES idempotent yang bisa dipanggil
--   berulang-ulang dari:
--     1. Tombol "🔄 Refresh" di dashboard Streamlit
--     2. Snowflake TASK terjadwal (scheduling otomatis)
--     3. Eksternal orchestrator (Airflow, dbt, dst.)
--
--   Bedanya dengan 03 & 04:
--     - 03/04 = SETUP & DEMO awal, dijalankan satu kali
--     - 05    = OPERASIONAL berkelanjutan, dijalankan kapanpun ada
--               regulasi baru, schema berubah, atau policy baru dipasang.
--   Hasil 03/04 dan hasil 05 SAMA-SAMA tabel COMPLIANCE_RESULTS, tapi 05
--   memisahkan hasil per use case agar dashboard bisa refresh per UC.
--
-- INPUT:
--   - Tabel hasil script 01 (CUSTOMER_DATA + TRANSACTION_DATA)
--   - Tabel REGULATIONS hasil script 02 (dengan kolom
--     REGULATION_SOURCE bernilai UU_PDP / KEBIJAKAN_KHUSUS /
--     BI_REGULATION)
--   - Placeholder <DB> harus diganti nama database aktual
--     (mis. BTN_COMPLIANCE_AI_DEMO) sebelum dijalankan
--
-- ISI / 4 STORED PROCEDURES:
--
--   1. SP_REFRESH_AI_CLASSIFICATION()
--      Re-klasifikasi SEMUA kolom in-scope (CUSTOMER_DATA +
--      TRANSACTION_DATA) menggunakan claude-opus-4-7. Fungsi sama
--      seperti script 03, tapi dipanggil setiap kali ada perubahan
--      schema. Output: tabel AI_CLASSIFICATION (overwrite).
--
--   2. SP_REFRESH_UC1()
--      ► Use Case 1: PII vs UU PDP / Privacy Regulation
--      Hanya men-scan kolom CONTAINS_PII = TRUE di CUSTOMER_DATA, lalu
--      mem-vonis terhadap pasal-pasal UU PDP. Pakai pre-filter (CROSS
--      JOIN dgn predicate kategori) supaya jumlah LLM call efisien.
--      Output: GAP_ANALYSIS_UC1.
--
--   3. SP_REFRESH_TX_GAP(REG_SOURCE)
--      ► Use Case 2 & 3: Transaksi vs Internal Policy / Regulator BI
--      Satu prosedur parametrik untuk dua UC sekaligus:
--          CALL SP_REFRESH_TX_GAP('KEBIJAKAN_KHUSUS')  → UC2
--          CALL SP_REFRESH_TX_GAP('BI_REGULATION')     → UC3
--      Hanya scan TRANSACTION_DATA, dan filter pasangan kolom×pasal
--      berdasarkan kategori (KYC_AML, FRAUD_PREVENTION,
--      SETTLEMENT_RISK, FOREIGN_EXCHANGE, AUDIT_TRAIL, dst).
--      Output: GAP_ANALYSIS_TRANSACTIONS (di-DELETE per REG_SOURCE
--      sebelum INSERT, jadi idempotent per source).
--
--   4. SP_REFRESH_UC4()
--      ► Use Case 4: Cross-Compare — Internal Policy vs Regulator BI
--      Setiap pasal BI di-cross check terhadap RINGKASAN seluruh
--      Kebijakan Khusus internal. AI menentukan apakah pasal BI
--      sudah TERCAKUP (FULL/PARTIAL/NONE) di kebijakan internal.
--      Output: GAP_ANALYSIS_UC4 dengan flag COVERED_IN_KEBIJAKAN +
--      coverage_quality + rekomendasi tambah/revisi pasal.
--
-- OUTPUT (tabel hasil refresh):
--   - COMPLIANCE_RESULTS.AI_CLASSIFICATION
--   - COMPLIANCE_RESULTS.GAP_ANALYSIS_UC1
--   - COMPLIANCE_RESULTS.GAP_ANALYSIS_TRANSACTIONS
--     (UC2 + UC3, dipisah per REGULATION_SOURCE)
--   - COMPLIANCE_RESULTS.GAP_ANALYSIS_UC4
--
--   Setiap baris hasil sudah berisi: IS_VIOLATION, FINDING (Bahasa
--   Indonesia), RECOMMENDATION, ANALYZED_AT — siap render di dashboard.
--
-- DEPENDENCY:
--   - Script 01 + 02 sudah dijalankan
--   - Tabel REGULATIONS sudah punya kolom REGULATION_SOURCE
--   - Cortex enabled (claude-opus-4-7 atau fallback claude-4-sonnet)
--   - Role pemanggil punya privilege:
--       USAGE on SNOWFLAKE.CORTEX
--       SELECT on tabel CUSTOMER_DATA.* + TRANSACTION_DATA.*
--       OWNERSHIP/MODIFY on COMPLIANCE_RESULTS.*
--
-- POSISI DI PIPELINE:
--   01_data_setup → 02_parse_documents → 03_ai_classification →
--   04_gap_analysis → [05_refresh_stored_procedures] → Streamlit
--
-- HUBUNGAN DENGAN SCRIPT LAIN:
--   - Script 03 = versi MANUAL untuk klasifikasi (one-shot demo)
--     Script 05 SP_REFRESH_AI_CLASSIFICATION = versi PROCEDURAL
--     (idempotent, bisa di-call berulang)
--   - Script 04 = versi MANUAL untuk gap analysis (1 tabel hasil)
--     Script 05 SP_REFRESH_UC1/UC2/UC3/UC4 = versi PROCEDURAL yang
--     dipisah per use case (4 tabel hasil) supaya dashboard bisa
--     refresh per UC tanpa rerun semuanya.
--   - Tombol "🔄 Refresh" di Streamlit (btn_compliance_dashboard.py)
--     memanggil prosedur-prosedur di sini.
--
-- KARAKTERISTIK PRODUCTION:
--   - IDEMPOTENT: aman dipanggil berulang. CREATE OR REPLACE TABLE atau
--     DELETE+INSERT mencegah duplikasi.
--   - JSON-FENCE-SAFE: pakai REGEXP_REPLACE menghapus ```json ... ```
--     sebelum TRY_PARSE_JSON, supaya tidak crash kalau LLM membungkus
--     output dengan markdown fence.
--   - PARAMETRIC: SP_REFRESH_TX_GAP menerima REG_SOURCE → satu prosedur
--     melayani UC2 dan UC3.
--   - COST-OPTIMIZED: pre-filter kategori (DATA_MASKING vs PII, KYC_AML
--     vs sensitive, dst.) supaya tidak semua kolom × semua pasal
--     dijalankan ke LLM.
--
-- CARA PEMAKAIAN:
--   USE DATABASE BTN_COMPLIANCE_AI_DEMO;
--   CALL COMPLIANCE_RESULTS.SP_REFRESH_AI_CLASSIFICATION();
--   CALL COMPLIANCE_RESULTS.SP_REFRESH_UC1();
--   CALL COMPLIANCE_RESULTS.SP_REFRESH_TX_GAP('KEBIJAKAN_KHUSUS');
--   CALL COMPLIANCE_RESULTS.SP_REFRESH_TX_GAP('BI_REGULATION');
--   CALL COMPLIANCE_RESULTS.SP_REFRESH_UC4();
--
-- CATATAN:
--   - Sebelum CREATE PROCEDURE, ganti placeholder <DB> dan <WH> dengan
--     nilai aktual (mis. BTN_COMPLIANCE_AI_DEMO + BTN_POC).
--   - Untuk schedule otomatis, bungkus 5 CALL di atas dengan
--     CREATE TASK ... SCHEDULE = 'USING CRON ...'.
-- =============================================================================
-- Phase 2 v2 - Stored Procedures for Compliance Refresh (claude-opus-4-7)
-- =============================================================================
-- These SPs are called by the dashboard's "🔄 Refresh" buttons. Replace
-- <DB> with the customer's database (e.g., BTN_COMPLIANCE_AI_DEMO).
-- =============================================================================
USE DATABASE <DB>;
USE WAREHOUSE <WH>;

-- -----------------------------------------------------------------------------
-- SP_REFRESH_AI_CLASSIFICATION — re-classify all in-scope columns with claude-opus-4-7
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE COMPLIANCE_RESULTS.SP_REFRESH_AI_CLASSIFICATION()
RETURNS STRING LANGUAGE SQL EXECUTE AS CALLER AS
$$
BEGIN
  CREATE OR REPLACE TABLE COMPLIANCE_RESULTS.AI_CLASSIFICATION AS
  WITH cols AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE
    FROM <DB>.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA IN ('CUSTOMER_DATA','TRANSACTION_DATA')
      AND TABLE_NAME IN ('NASABAH','REKENING','KARTU_KREDIT','LOAN_APPLICATION',
                         'TLHIST_TRANSAKSI','GOAML_ODM_TRANSAKSI','RTGS_SKNBI_PAYMENT')
  ),
  raw AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
      SNOWFLAKE.CORTEX.COMPLETE('claude-opus-4-7',
        'Klasifikasikan kolom database perbankan Indonesia berikut.\nSchema: ' || TABLE_SCHEMA ||
        '\nTabel: ' || TABLE_NAME || '\nKolom: ' || COLUMN_NAME || '\nTipe: ' || DATA_TYPE ||
        '\n\nReturn HANYA JSON valid (tanpa markdown):\n{"classification":"<IDENTIFIER|QUASI_IDENTIFIER|FINANCIAL|SENSITIVE_PII|TRANSACTION_ATTR|NON_SENSITIVE>","sensitivity":"<CRITICAL|HIGH|MEDIUM|LOW>","needs_masking":<true|false>,"contains_pii":<true|false>,"risk_level":"<CRITICAL|HIGH|MEDIUM|LOW>","reason":"penjelasan singkat bahasa Indonesia max 25 kata"}'
      ) AS llm_resp
    FROM cols
  )
  SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):classification::VARCHAR) AS AI_CLASSIFICATION,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):sensitivity::VARCHAR) AS AI_SENSITIVITY,
    TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):needs_masking::BOOLEAN AS NEEDS_MASKING,
    TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):contains_pii::BOOLEAN AS CONTAINS_PII,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):risk_level::VARCHAR) AS RISK_LEVEL,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):reason::VARCHAR) AS AI_REASON,
    CURRENT_TIMESTAMP() AS CLASSIFIED_AT
  FROM raw;
  RETURN 'AI_CLASSIFICATION refreshed: ' || (SELECT COUNT(*) FROM COMPLIANCE_RESULTS.AI_CLASSIFICATION) || ' columns';
END;
$$;

-- -----------------------------------------------------------------------------
-- SP_REFRESH_UC1 — UU PDP / privacy regulation vs customer/PII tables
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE COMPLIANCE_RESULTS.SP_REFRESH_UC1()
RETURNS STRING LANGUAGE SQL EXECUTE AS CALLER AS
$$
BEGIN
  -- NOTE: DATA_RETENTION pasal sengaja DI-EXCLUDE dari analisa
  -- (per feedback user: rules retensi tidak perlu dianalisa di POC ini).
  CREATE OR REPLACE TABLE COMPLIANCE_RESULTS.GAP_ANALYSIS_UC1 AS
  WITH cols AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, AI_CLASSIFICATION, AI_SENSITIVITY, RISK_LEVEL, AI_REASON, CONTAINS_PII, NEEDS_MASKING
    FROM COMPLIANCE_RESULTS.AI_CLASSIFICATION
    WHERE TABLE_SCHEMA='CUSTOMER_DATA' AND CONTAINS_PII = TRUE
  ),
  regs AS (
    SELECT REG_ID, PASAL, CATEGORY, TITLE, SEVERITY, CONTENT, APPLIES_TO
    FROM COMPLIANCE_DOCS.REGULATIONS
    WHERE REGULATION_SOURCE='UU_PDP'
      AND UPPER(CATEGORY) <> 'DATA_RETENTION'
  ),
  pairs AS (
    SELECT c.*, r.REG_ID, r.PASAL, r.CATEGORY AS REG_CATEGORY, r.TITLE AS REG_TITLE,
           r.SEVERITY AS REG_SEVERITY, r.CONTENT AS REG_CONTENT, r.APPLIES_TO
    FROM cols c CROSS JOIN regs r
    WHERE (r.CATEGORY IN ('DATA_MASKING','ENCRYPTION') AND c.NEEDS_MASKING=TRUE)
       OR (r.CATEGORY='DATA_CLASSIFICATION')
       OR (r.CATEGORY='ACCESS_CONTROL' AND c.AI_SENSITIVITY IN ('CRITICAL','HIGH'))
       OR (r.CATEGORY='AUDIT_TRAIL')
  ),
  raw AS (
    SELECT *,
      SNOWFLAKE.CORTEX.COMPLETE('claude-opus-4-7',
        'Bank punya kolom data PII plain-text. KOLOM: ' || TABLE_NAME || '.' || COLUMN_NAME ||
        ' (' || DATA_TYPE || ', ' || AI_CLASSIFICATION || ')\nKONTEKS: ' || AI_REASON ||
        '\n\nREGULASI Privacy - Pasal: ' || PASAL || ' | ' || REG_TITLE || ' | KATEGORI: ' || REG_CATEGORY ||
        '\nIsi: ' || LEFT(REG_CONTENT, 1500) ||
        '\n\nCATATAN PLATFORM (PENTING - JANGAN DILANGGAR):\n' ||
        '- Snowflake SUDAH menyediakan AUDIT TRAIL built-in (ACCESS_HISTORY, QUERY_HISTORY, LOGIN_HISTORY) tanpa konfigurasi tambahan.\n' ||
        '- Semua data terenkripsi at-rest (AES-256) dan in-transit (TLS 1.2+) by default.\n' ||
        '- JANGAN tandai sebagai VIOLATION untuk: AUDIT_TRAIL atau ENCRYPTION at-rest. Set is_violation=false.\n\n' ||
        'ATURAN KONSISTENSI KATEGORI (WAJIB):\n' ||
        '- DATA_MASKING / ENCRYPTION → Dynamic Data Masking Policy / Tag-based masking.\n' ||
        '- ACCESS_CONTROL → Row Access Policy + RBAC + role least-privilege.\n' ||
        '- DATA_CLASSIFICATION → object tagging (PII, PII_FINANCIAL), classification framework.\n' ||
        '- AUDIT_TRAIL → set is_violation=false (Snowflake built-in).\n' ||
        '- NETWORK_SECURITY → NETWORK POLICY, IP allowlist, private link.\n\n' ||
        'Apakah kolom comply terhadap pasal ini? Return JSON saja:\n{"is_violation":<true|false>,"violation_type":"<MASKING_MISSING|ENCRYPTION_MISSING|ACCESS_CONTROL_MISSING|AUDIT_LOG_MISSING|CLASSIFICATION_MISSING|N/A>","severity":"<CRITICAL|HIGH|MEDIUM|LOW>","finding":"deskripsi 1 kalimat bahasa Indonesia, sebut nama pasal/kategori","recommendation":"rekomendasi 1-2 kalimat bahasa Indonesia, harus sesuai KATEGORI pasal di atas"}'
      ) AS llm_resp
    FROM pairs
  )
  SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, AI_CLASSIFICATION, AI_SENSITIVITY, RISK_LEVEL,
    REG_ID, PASAL, REG_CATEGORY, REG_TITLE, REG_SEVERITY,
    COALESCE(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):is_violation::BOOLEAN, FALSE) AS IS_VIOLATION,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):violation_type::VARCHAR) AS VIOLATION_TYPE,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):severity::VARCHAR) AS FINDING_SEVERITY,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):finding::VARCHAR) AS FINDING,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):recommendation::VARCHAR) AS RECOMMENDATION,
    CURRENT_TIMESTAMP() AS ANALYZED_AT
  FROM raw;

  -- Post-filter A: AUDIT/ENCRYPTION → COMPLIANT (Snowflake built-in)
  UPDATE COMPLIANCE_RESULTS.GAP_ANALYSIS_UC1
     SET IS_VIOLATION    = FALSE,
         VIOLATION_TYPE  = 'N/A',
         FINDING         = 'COMPLIANT - Snowflake menyediakan audit trail (ACCESS_HISTORY/QUERY_HISTORY) dan enkripsi at-rest (AES-256) secara built-in tanpa konfigurasi tambahan.',
         RECOMMENDATION  = 'Tidak perlu tindakan: cukup pastikan SNOWFLAKE.ACCOUNT_USAGE share aktif untuk monitoring audit trail.'
   WHERE UPPER(VIOLATION_TYPE) IN ('AUDIT_LOG_MISSING','ENCRYPTION_MISSING')
      OR UPPER(REG_CATEGORY) IN ('AUDIT_TRAIL','ENCRYPTION');

  RETURN 'UC1 refreshed: ' || (SELECT COUNT(*) FROM COMPLIANCE_RESULTS.GAP_ANALYSIS_UC1) || ' pairs';
END;
$$;

-- -----------------------------------------------------------------------------
-- SP_REFRESH_TX_GAP(REG_SOURCE) — UC2 (KEBIJAKAN_KHUSUS) or UC3 (BI_REGULATION)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE COMPLIANCE_RESULTS.SP_REFRESH_TX_GAP(REG_SOURCE STRING)
RETURNS STRING LANGUAGE SQL EXECUTE AS CALLER AS
$$
DECLARE
  rc INTEGER;
BEGIN
  -- NOTE: DATA_RETENTION pasal sengaja DI-EXCLUDE dari analisa
  -- (per feedback user: rules retensi tidak perlu dianalisa di POC ini).
  DELETE FROM COMPLIANCE_RESULTS.GAP_ANALYSIS_TRANSACTIONS WHERE REGULATION_SOURCE = :REG_SOURCE;

  INSERT INTO COMPLIANCE_RESULTS.GAP_ANALYSIS_TRANSACTIONS
    (TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, AI_CLASSIFICATION, AI_SENSITIVITY, RISK_LEVEL,
     REG_ID, REGULATION_SOURCE, PASAL, REG_CATEGORY, REG_TITLE, REG_SEVERITY,
     IS_VIOLATION, VIOLATION_TYPE, FINDING_SEVERITY, FINDING, RECOMMENDATION, ANALYZED_AT)
  WITH cols AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, AI_CLASSIFICATION, AI_SENSITIVITY, RISK_LEVEL, AI_REASON, CONTAINS_PII, NEEDS_MASKING
    FROM COMPLIANCE_RESULTS.AI_CLASSIFICATION WHERE TABLE_SCHEMA='TRANSACTION_DATA'
  ),
  regs AS (
    SELECT REG_ID, REGULATION_SOURCE, PASAL, CATEGORY, TITLE, SEVERITY, CONTENT, APPLIES_TO
    FROM COMPLIANCE_DOCS.REGULATIONS
    WHERE REGULATION_SOURCE = :REG_SOURCE
      AND UPPER(CATEGORY) <> 'DATA_RETENTION'
  ),
  pairs AS (
    SELECT c.*, r.REG_ID, r.REGULATION_SOURCE, r.PASAL, r.CATEGORY AS REG_CATEGORY,
           r.TITLE AS REG_TITLE, r.SEVERITY AS REG_SEVERITY, r.CONTENT AS REG_CONTENT, r.APPLIES_TO
    FROM cols c JOIN regs r ON
      (r.CATEGORY IN ('KYC_AML','TRANSACTION_REPORTING','FRAUD_PREVENTION') AND c.AI_SENSITIVITY IN ('CRITICAL','HIGH'))
      OR (r.CATEGORY IN ('SETTLEMENT_RISK','OPERATIONAL_RISK') AND c.TABLE_NAME='RTGS_SKNBI_PAYMENT')
      OR (r.CATEGORY = 'FOREIGN_EXCHANGE' AND c.COLUMN_NAME ILIKE ANY('%CCY%','%CURRENCY%','%XRATE%','%SWIFT%','%CNTRY%','%BIC%'))
      OR (r.CATEGORY IN ('DATA_MASKING','ACCESS_CONTROL','AUDIT_TRAIL','REPORTING') AND c.CONTAINS_PII=TRUE)
  ),
  raw AS (
    SELECT *,
      SNOWFLAKE.CORTEX.COMPLETE('claude-opus-4-7',
        'Bank. KOLOM: ' || TABLE_SCHEMA || '.' || TABLE_NAME || '.' || COLUMN_NAME ||
        ' (' || DATA_TYPE || ', ' || AI_CLASSIFICATION || ')\nKONTEKS: ' || AI_REASON ||
        '\n\nREGULASI (' || REGULATION_SOURCE || ') Pasal ' || PASAL || ': ' || REG_TITLE || ' | KATEGORI: ' || REG_CATEGORY ||
        '\nIsi: ' || LEFT(REG_CONTENT,1500) ||
        '\n\nCATATAN PLATFORM (PENTING - JANGAN DILANGGAR):\n' ||
        '- Snowflake SUDAH menyediakan AUDIT TRAIL built-in (ACCESS_HISTORY, QUERY_HISTORY, LOGIN_HISTORY) tanpa konfigurasi tambahan.\n' ||
        '- Semua data terenkripsi at-rest (AES-256) dan in-transit (TLS 1.2+) by default.\n' ||
        '- JANGAN tandai sebagai VIOLATION untuk: AUDIT_TRAIL atau ENCRYPTION at-rest. Set is_violation=false.\n\n' ||
        'ATURAN KONSISTENSI KATEGORI (WAJIB):\n' ||
        '- DATA_MASKING / ENCRYPTION → Dynamic Data Masking Policy.\n' ||
        '- ACCESS_CONTROL → Row Access Policy + RBAC + least-privilege role.\n' ||
        '- DATA_CLASSIFICATION → object tagging, classification framework.\n' ||
        '- KYC_AML / FRAUD_PREVENTION → identity verification, AML screening, suspicious transaction reporting.\n' ||
        '- TRANSACTION_REPORTING / REPORTING → regulatory reporting pipeline (LTKM/LTKT/SLIK), threshold alerts.\n' ||
        '- SETTLEMENT_RISK / OPERATIONAL_RISK → dual-control approval, settlement monitoring.\n' ||
        '- FOREIGN_EXCHANGE → FX rate validation, threshold cross-border, BI devisa reporting.\n' ||
        '- AUDIT_TRAIL → set is_violation=false (Snowflake built-in).\n\n' ||
        'Apakah kolom berkaitan & comply? Return JSON:\n{"is_violation":<true|false>,"violation_type":"<MASKING_MISSING|AUDIT_LOG_MISSING|KYC_MISSING|AML_SCREENING_MISSING|REPORTING_MISSING|ACCESS_CONTROL_MISSING|N/A>","severity":"<CRITICAL|HIGH|MEDIUM|LOW>","finding":"1 kalimat bahasa Indonesia, sebut nama pasal/kategori","recommendation":"remediasi 1-2 kalimat bahasa Indonesia, harus sesuai KATEGORI pasal di atas"}'
      ) AS llm_resp
    FROM pairs
  )
  SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, AI_CLASSIFICATION, AI_SENSITIVITY, RISK_LEVEL,
    REG_ID, REGULATION_SOURCE, PASAL, REG_CATEGORY, REG_TITLE, REG_SEVERITY,
    COALESCE(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):is_violation::BOOLEAN, FALSE) AS IS_VIOLATION,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):violation_type::VARCHAR) AS VIOLATION_TYPE,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):severity::VARCHAR) AS FINDING_SEVERITY,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):finding::VARCHAR) AS FINDING,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):recommendation::VARCHAR) AS RECOMMENDATION,
    CURRENT_TIMESTAMP() AS ANALYZED_AT
  FROM raw;

  -- Post-filter: AUDIT/ENCRYPTION → COMPLIANT (Snowflake built-in)
  UPDATE COMPLIANCE_RESULTS.GAP_ANALYSIS_TRANSACTIONS
     SET IS_VIOLATION    = FALSE,
         VIOLATION_TYPE  = 'N/A',
         FINDING         = 'COMPLIANT - Snowflake menyediakan audit trail (ACCESS_HISTORY/QUERY_HISTORY) dan enkripsi at-rest (AES-256) secara built-in tanpa konfigurasi tambahan.',
         RECOMMENDATION  = 'Tidak perlu tindakan: pastikan SNOWFLAKE.ACCOUNT_USAGE share aktif untuk monitoring audit trail.'
   WHERE REGULATION_SOURCE = :REG_SOURCE
     AND ( UPPER(VIOLATION_TYPE) IN ('AUDIT_LOG_MISSING','ENCRYPTION_MISSING')
        OR UPPER(REG_CATEGORY) IN ('AUDIT_TRAIL','ENCRYPTION') );

  rc := (SELECT COUNT(*) FROM COMPLIANCE_RESULTS.GAP_ANALYSIS_TRANSACTIONS WHERE REGULATION_SOURCE = :REG_SOURCE);
  RETURN 'TX gap (' || :REG_SOURCE || ') refreshed: ' || rc || ' pairs';
END;
$$;

-- -----------------------------------------------------------------------------
-- SP_REFRESH_UC4 — Internal policies vs Regulator regulations cross-comparison
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE COMPLIANCE_RESULTS.SP_REFRESH_UC4()
RETURNS STRING LANGUAGE SQL EXECUTE AS CALLER AS
$$
BEGIN
  CREATE OR REPLACE TABLE COMPLIANCE_RESULTS.GAP_ANALYSIS_UC4 AS
  WITH bi AS (
    SELECT REG_ID, PASAL, CATEGORY, TITLE, CONTENT, APPLIES_TO, SEVERITY
    FROM COMPLIANCE_DOCS.REGULATIONS WHERE REGULATION_SOURCE='BI_REGULATION'
  ),
  keb_summary AS (
    SELECT LISTAGG('[KEB-' || REG_ID || ' / ' || PASAL || '] ' || TITLE || ' :: ' || LEFT(CONTENT,400),
                   ' || ') WITHIN GROUP (ORDER BY REG_ID) AS keb_text
    FROM COMPLIANCE_DOCS.REGULATIONS WHERE REGULATION_SOURCE='KEBIJAKAN_KHUSUS'
  ),
  raw AS (
    SELECT bi.REG_ID AS BI_REG_ID, bi.PASAL AS BI_PASAL, bi.CATEGORY AS BI_CATEGORY,
           bi.TITLE AS BI_TITLE, bi.SEVERITY AS BI_SEVERITY,
      SNOWFLAKE.CORTEX.COMPLETE('claude-opus-4-7',
        'Auditor kebijakan bank. Periksa apakah aturan regulator berikut sudah TERCAKUP di Kebijakan Khusus internal.\n\nATURAN REGULATOR: ID ' || bi.REG_ID || ' Pasal ' || bi.PASAL ||
        ' Kategori ' || bi.CATEGORY || ' Title: ' || bi.TITLE ||
        ' Berlaku: ' || COALESCE(bi.APPLIES_TO,'-') || ' Isi: ' || LEFT(bi.CONTENT, 1200) ||
        '\n\nKEBIJAKAN KHUSUS BANK:\n' || LEFT(k.keb_text, 12000) ||
        '\n\nReturn JSON:\n{"covered_in_kebijakan":<true|false>,"matching_keb_id":"ID kebijakan match (atau NONE)","coverage_quality":"<FULL|PARTIAL|NONE>","gap_finding":"penjelasan singkat (Bahasa Indonesia) bagian yg tdk tercakup, atau N/A","recommendation":"rekomendasi tambah/revisi pasal apa di kebijakan khusus"}'
      ) AS llm_resp
    FROM bi CROSS JOIN keb_summary k
  )
  SELECT BI_REG_ID, BI_PASAL, BI_CATEGORY, BI_TITLE, BI_SEVERITY,
    COALESCE(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):covered_in_kebijakan::BOOLEAN, FALSE) AS COVERED_IN_KEBIJAKAN,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):matching_keb_id::VARCHAR) AS MATCHING_KEB_ID,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):coverage_quality::VARCHAR) AS COVERAGE_QUALITY,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):gap_finding::VARCHAR) AS GAP_FINDING,
    TRIM(TRY_PARSE_JSON(REGEXP_REPLACE(REGEXP_REPLACE(llm_resp,'^[ \\n]*```(json)?',''),'```[ \\n]*$','')):recommendation::VARCHAR) AS RECOMMENDATION,
    CURRENT_TIMESTAMP() AS ANALYZED_AT
  FROM raw;
  RETURN 'UC4 refreshed: ' || (SELECT COUNT(*) FROM COMPLIANCE_RESULTS.GAP_ANALYSIS_UC4) || ' BI rules';
END;
$$;

-- -----------------------------------------------------------------------------
-- Initial population (call all once)
-- -----------------------------------------------------------------------------
-- CALL COMPLIANCE_RESULTS.SP_REFRESH_AI_CLASSIFICATION();
-- CALL COMPLIANCE_RESULTS.SP_REFRESH_UC1();
-- CALL COMPLIANCE_RESULTS.SP_REFRESH_TX_GAP('KEBIJAKAN_KHUSUS');
-- CALL COMPLIANCE_RESULTS.SP_REFRESH_TX_GAP('BI_REGULATION');
-- CALL COMPLIANCE_RESULTS.SP_REFRESH_UC4();
