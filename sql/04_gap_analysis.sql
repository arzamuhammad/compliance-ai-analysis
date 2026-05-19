-- ============================================================================
-- STEP 5: AI COMPLIANCE GAP ANALYSIS (Full AI-Driven)
-- Feature: Cortex LLM MEMBACA isi regulasi dan MENCOCOKKAN dengan kolom
-- 
-- Cara kerja (v3.0 - Full AI-Driven):
--   1. Collect governance state (masking policies, RAP, time travel)
--   2. Build context: semua kolom + AI classification + governance status
--   3. Per regulasi: Cortex LLM membaca CONTENT regulasi (dari PDF) 
--      dan menganalisis semua kolom yang RELEVAN → COMPLIANT/VIOLATION
--   4. Flatten JSON findings → INSERT ke tabel
--
-- BUKAN hardcoded mapping! AI benar-benar memahami isi regulasi.
-- ============================================================================

-- 5a. Buat Stored Procedure untuk Gap Analysis
CREATE OR REPLACE PROCEDURE COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_AI_GAP_ANALYSIS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    -- ================================================================
    -- SP_AI_GAP_ANALYSIS v3.0 - FULL AI-DRIVEN
    -- 
    -- AI benar-benar MEMBACA isi regulasi dari PDF (tabel REGULATIONS)
    -- dan MENCOCOKKAN dengan kolom-kolom yang ada di database.
    -- 
    -- Flow: 
    --   1. Kumpulkan governance state (masking, RAP, tags, retention)
    --   2. Per regulasi → Cortex LLM baca CONTENT + kolom → findings
    --   3. Flatten JSON → INSERT ke COMPLIANCE_GAP_ANALYSIS
    -- ================================================================

    -- Recreate the gap analysis table
    CREATE OR REPLACE TABLE COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS (
        TABLE_NAME VARCHAR(100),
        COLUMN_NAME VARCHAR(100),
        REGULATION_ID VARCHAR(10),
        REGULATION_NAME VARCHAR(200),
        REGULATION_TITLE VARCHAR(200),
        SEVERITY VARCHAR(20),
        CATEGORY VARCHAR(50),
        CHECK_TYPE VARCHAR(50),
        STATUS VARCHAR(20),
        FINDING TEXT,
        RECOMMENDATION TEXT,
        ANALYZED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
    );

    -- ================================================================
    -- STEP 1: Collect governance state
    -- ================================================================

    -- 1a. Masking policies
    CREATE OR REPLACE TEMPORARY TABLE _tmp_masking_refs AS
    SELECT REF_ENTITY_NAME AS TABLE_NAME, REF_COLUMN_NAME AS COLUMN_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.NASABAH', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'MASKING_POLICY'
    UNION ALL
    SELECT REF_ENTITY_NAME, REF_COLUMN_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.REKENING', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'MASKING_POLICY'
    UNION ALL
    SELECT REF_ENTITY_NAME, REF_COLUMN_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.KARTU_KREDIT', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'MASKING_POLICY'
    UNION ALL
    SELECT REF_ENTITY_NAME, REF_COLUMN_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.TRANSAKSI', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'MASKING_POLICY'
    UNION ALL
    SELECT REF_ENTITY_NAME, REF_COLUMN_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.LOAN_APPLICATION', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'MASKING_POLICY';

    -- 1b. Row access policies
    CREATE OR REPLACE TEMPORARY TABLE _tmp_rap_refs AS
    SELECT DISTINCT REF_ENTITY_NAME AS TABLE_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.NASABAH', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'ROW_ACCESS_POLICY'
    UNION
    SELECT DISTINCT REF_ENTITY_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.KARTU_KREDIT', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'ROW_ACCESS_POLICY'
    UNION
    SELECT DISTINCT REF_ENTITY_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.REKENING', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'ROW_ACCESS_POLICY'
    UNION
    SELECT DISTINCT REF_ENTITY_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.TRANSAKSI', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'ROW_ACCESS_POLICY'
    UNION
    SELECT DISTINCT REF_ENTITY_NAME
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'COMPLIANCE_AI_DEMO.CUSTOMER_DATA.LOAN_APPLICATION', REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'ROW_ACCESS_POLICY';

    -- ================================================================
    -- STEP 2: Build context string (governance state summary)
    -- ================================================================
    
    -- 2a. Column context: semua kolom + classification + masking status
    CREATE OR REPLACE TEMPORARY TABLE _tmp_column_context AS
    SELECT LISTAGG(
        ac.TABLE_NAME || '.' || ac.COLUMN_NAME || 
        ' | tipe=' || ac.DATA_TYPE || 
        ' | klasifikasi=' || ac.AI_CLASSIFICATION || 
        ' | sensitivitas=' || ac.AI_SENSITIVITY ||
        ' | risk=' || ac.RISK_LEVEL ||
        ' | masking_policy=' || CASE WHEN m.COLUMN_NAME IS NOT NULL THEN 'ADA' ELSE 'TIDAK_ADA' END,
        '\n'
    ) WITHIN GROUP (ORDER BY ac.TABLE_NAME, ac.COLUMN_NAME) AS CONTEXT
    FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION ac
    LEFT JOIN _tmp_masking_refs m 
        ON m.TABLE_NAME LIKE '%' || ac.TABLE_NAME AND m.COLUMN_NAME = ac.COLUMN_NAME;

    -- 2b. Table-level context: RAP + time travel
    CREATE OR REPLACE TEMPORARY TABLE _tmp_table_context AS
    SELECT LISTAGG(
        t.TABLE_NAME || 
        ' | row_access_policy=' || CASE WHEN rap.TABLE_NAME IS NOT NULL THEN 'ADA' ELSE 'TIDAK_ADA' END ||
        ' | time_travel_days=' || t.RETENTION_TIME ||
        ' | network_policy=TIDAK_ADA',
        '\n'
    ) WITHIN GROUP (ORDER BY t.TABLE_NAME) AS CONTEXT
    FROM COMPLIANCE_AI_DEMO.INFORMATION_SCHEMA.TABLES t
    LEFT JOIN _tmp_rap_refs rap ON rap.TABLE_NAME LIKE '%' || t.TABLE_NAME
    WHERE t.TABLE_SCHEMA = 'CUSTOMER_DATA'
      AND t.TABLE_NAME IN ('NASABAH','REKENING','KARTU_KREDIT','TRANSAKSI','LOAN_APPLICATION');

    -- ================================================================
    -- STEP 3: AI-driven analysis per regulation (12 LLM calls)
    -- Setiap regulasi di-analisis oleh LLM terhadap SEMUA kolom
    -- ================================================================
    CREATE OR REPLACE TEMPORARY TABLE _tmp_ai_findings AS
    SELECT 
        r.REG_ID,
        r.REGULATION_NAME,
        r.PASAL,
        r.TITLE,
        r.SEVERITY,
        r.CATEGORY,
        SNOWFLAKE.CORTEX.COMPLETE(
            'claude-4-sonnet',
            'Kamu adalah Compliance Auditor untuk bank di Indonesia. Tugasmu: menganalisis apakah kolom-kolom database MEMATUHI regulasi yang diberikan.

== REGULASI YANG DIANALISIS ==
ID: ' || r.REG_ID || '
Nama: ' || r.REGULATION_NAME || ' - ' || r.PASAL || '
Kategori: ' || r.CATEGORY || '
Severity: ' || r.SEVERITY || '
Isi Regulasi: ' || r.CONTENT || '

== DATA KOLOM DATABASE (format: tabel.kolom | tipe | klasifikasi_AI | sensitivitas | risk | status_masking_policy) ==
' || (SELECT CONTEXT FROM _tmp_column_context) || '

== DATA TABEL (format: tabel | status_row_access_policy | time_travel | network_policy) ==
' || (SELECT CONTEXT FROM _tmp_table_context) || '

== INSTRUKSI ==
Berdasarkan ISI REGULASI di atas, identifikasi SEMUA kolom/tabel yang RELEVAN dengan regulasi ini. Untuk setiap kolom/tabel yang relevan, tentukan apakah COMPLIANT, VIOLATION, atau WARNING.

Aturan penentuan status:
- Jika regulasi mewajibkan masking_policy dan kolom tidak punya → VIOLATION
- Jika regulasi mewajibkan row_access_policy dan tabel tidak punya → VIOLATION
- Jika regulasi mewajibkan tag/klasifikasi dan kolom belum di-tag → VIOLATION
- Jika regulasi mewajibkan data TIDAK BOLEH disimpan (mis. CVV) → VIOLATION
- Jika regulasi tentang time_travel dan retention < yang diminta → VIOLATION
- Jika regulasi tentang audit trail dan Snowflake sudah built-in → COMPLIANT
- Jika regulasi tentang network_policy dan belum dikonfigurasi → WARNING
- Kolom NON_SENSITIVE bisa diabaikan (tidak perlu dilaporkan)

Kembalikan HANYA valid JSON array (tanpa markdown, tanpa backtick, tanpa penjelasan):
[{"table_name":"...","column_name":"...","check_type":"MASKING_POLICY|ROW_ACCESS_POLICY|TAG|ENCRYPTION|TIME_TRAVEL|CVV_STORAGE|ACCESS_HISTORY|NETWORK_POLICY","status":"COMPLIANT|VIOLATION|WARNING","finding":"<penjelasan spesifik dalam Bahasa Indonesia, sebutkan nama kolom dan tabel>","recommendation":"<rekomendasi spesifik dan actionable>"}]

Jika regulasi ini TIDAK relevan dengan kolom manapun, kembalikan: []
PENTING: Fokus HANYA pada kolom yang benar-benar disebutkan atau dimaksud oleh regulasi. Jangan over-report.'
        ) AS LLM_RESPONSE
    FROM COMPLIANCE_AI_DEMO.COMPLIANCE_DOCS.REGULATIONS r;

    -- ================================================================
    -- STEP 4: Flatten JSON findings → INSERT ke tabel hasil
    -- ================================================================
    INSERT INTO COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS
        (TABLE_NAME, COLUMN_NAME, REGULATION_ID, REGULATION_NAME, REGULATION_TITLE, 
         SEVERITY, CATEGORY, CHECK_TYPE, STATUS, FINDING, RECOMMENDATION)
    SELECT 
        f.value:table_name::VARCHAR,
        f.value:column_name::VARCHAR,
        af.REG_ID,
        af.REGULATION_NAME || ' - ' || af.PASAL,
        af.TITLE,
        af.SEVERITY,
        af.CATEGORY,
        f.value:check_type::VARCHAR,
        f.value:status::VARCHAR,
        f.value:finding::VARCHAR,
        f.value:recommendation::VARCHAR
    FROM _tmp_ai_findings af,
        LATERAL FLATTEN(input => TRY_PARSE_JSON(af.LLM_RESPONSE)) f
    WHERE TRY_PARSE_JSON(af.LLM_RESPONSE) IS NOT NULL;

    -- ================================================================
    -- CLEANUP
    -- ================================================================
    DROP TABLE IF EXISTS _tmp_masking_refs;
    DROP TABLE IF EXISTS _tmp_rap_refs;
    DROP TABLE IF EXISTS _tmp_column_context;
    DROP TABLE IF EXISTS _tmp_table_context;
    DROP TABLE IF EXISTS _tmp_ai_findings;

    LET total_findings INTEGER := (SELECT COUNT(*) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS);
    LET total_violations INTEGER := (SELECT COUNT(*) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS WHERE STATUS = 'VIOLATION');
    LET total_regs INTEGER := (SELECT COUNT(DISTINCT REGULATION_ID) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS);

    RETURN 'AI Gap Analysis completed. ' || :total_findings || ' findings (' || :total_violations || ' violations) across ' || :total_regs || ' regulations.';
END;
$$;

-- 5b. Buat Views untuk Summary
CREATE OR REPLACE VIEW COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_OVERALL_COMPLIANCE AS
SELECT 
    COUNT(*) AS TOTAL_CHECKS,
    SUM(CASE WHEN STATUS = 'VIOLATION' THEN 1 ELSE 0 END) AS TOTAL_VIOLATIONS,
    SUM(CASE WHEN STATUS = 'COMPLIANT' THEN 1 ELSE 0 END) AS TOTAL_COMPLIANT,
    SUM(CASE WHEN STATUS = 'WARNING' THEN 1 ELSE 0 END) AS TOTAL_WARNINGS,
    SUM(CASE WHEN STATUS = 'VIOLATION' AND SEVERITY = 'CRITICAL' THEN 1 ELSE 0 END) AS CRITICAL_COUNT,
    SUM(CASE WHEN STATUS = 'VIOLATION' AND SEVERITY = 'HIGH' THEN 1 ELSE 0 END) AS HIGH_COUNT,
    SUM(CASE WHEN STATUS = 'VIOLATION' AND SEVERITY = 'MEDIUM' THEN 1 ELSE 0 END) AS MEDIUM_COUNT,
    COUNT(DISTINCT TABLE_NAME) AS TABLES_SCANNED,
    ROUND(SUM(CASE WHEN STATUS = 'COMPLIANT' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS OVERALL_SCORE
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS;

CREATE OR REPLACE VIEW COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_COMPLIANCE_SCORE_BY_TABLE AS
SELECT 
    TABLE_NAME,
    COUNT(*) AS TOTAL_CHECKS,
    SUM(CASE WHEN STATUS = 'VIOLATION' THEN 1 ELSE 0 END) AS VIOLATION_COUNT,
    SUM(CASE WHEN STATUS = 'COMPLIANT' THEN 1 ELSE 0 END) AS COMPLIANT_COUNT,
    SUM(CASE WHEN STATUS = 'VIOLATION' AND SEVERITY = 'CRITICAL' THEN 1 ELSE 0 END) AS CRITICAL_VIOLATIONS,
    SUM(CASE WHEN STATUS = 'VIOLATION' AND SEVERITY = 'HIGH' THEN 1 ELSE 0 END) AS HIGH_VIOLATIONS,
    ROUND(SUM(CASE WHEN STATUS = 'COMPLIANT' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS COMPLIANCE_SCORE
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS
GROUP BY TABLE_NAME
ORDER BY COMPLIANCE_SCORE ASC;

CREATE OR REPLACE VIEW COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_COMPLIANCE_SCORE_BY_REGULATION AS
SELECT 
    REGULATION_ID,
    REGULATION_NAME,
    REGULATION_TITLE,
    SEVERITY,
    CATEGORY,
    COUNT(*) AS TOTAL_CHECKS,
    SUM(CASE WHEN STATUS = 'VIOLATION' THEN 1 ELSE 0 END) AS VIOLATION_COUNT,
    SUM(CASE WHEN STATUS = 'COMPLIANT' THEN 1 ELSE 0 END) AS COMPLIANT_COUNT,
    ROUND(SUM(CASE WHEN STATUS = 'COMPLIANT' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS COMPLIANCE_SCORE
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS
GROUP BY REGULATION_ID, REGULATION_NAME, REGULATION_TITLE, SEVERITY, CATEGORY
ORDER BY COMPLIANCE_SCORE ASC;

-- 5c. Jalankan Gap Analysis (~1-2 menit, 12 LLM calls)
CALL COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_AI_GAP_ANALYSIS();

-- 5d. Lihat overall compliance score
SELECT * FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_OVERALL_COMPLIANCE;

-- 5e. Score per tabel
SELECT * FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_COMPLIANCE_SCORE_BY_TABLE;

-- 5f. Score per regulasi
SELECT * FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_COMPLIANCE_SCORE_BY_REGULATION;

-- 5g. Top CRITICAL violations
SELECT TABLE_NAME, COLUMN_NAME, REGULATION_ID, REGULATION_TITLE, SEVERITY, FINDING
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.COMPLIANCE_GAP_ANALYSIS
WHERE STATUS = 'VIOLATION' AND SEVERITY = 'CRITICAL'
ORDER BY REGULATION_ID;
