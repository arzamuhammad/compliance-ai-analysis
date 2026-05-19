-- ============================================================================
-- STEP 4: AI DATA CLASSIFICATION (Cortex LLM)
-- Feature: Cortex COMPLETE - AI classifies every column automatically
-- ============================================================================

-- 4a. Buat Stored Procedure untuk AI Classification
CREATE OR REPLACE PROCEDURE COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_AI_CLASSIFY_COLUMNS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    -- Truncate existing results
    TRUNCATE TABLE IF EXISTS COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION;
    
    -- Recreate table with proper structure
    CREATE OR REPLACE TABLE COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION (
        TABLE_NAME VARCHAR(100),
        COLUMN_NAME VARCHAR(100),
        DATA_TYPE VARCHAR(50),
        SAMPLE_VALUES TEXT,
        AI_CLASSIFICATION VARCHAR(50),
        AI_SENSITIVITY VARCHAR(20),
        NEEDS_MASKING BOOLEAN,
        NEEDS_TAG BOOLEAN,
        RISK_LEVEL VARCHAR(20),
        AI_REASON TEXT,
        CLASSIFIED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
    );
    
    -- Use Cortex LLM to classify each column
    INSERT INTO COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION
        (TABLE_NAME, COLUMN_NAME, DATA_TYPE, SAMPLE_VALUES, AI_CLASSIFICATION, AI_SENSITIVITY, NEEDS_MASKING, NEEDS_TAG, RISK_LEVEL, AI_REASON)
    WITH column_info AS (
        SELECT 
            TABLE_NAME,
            COLUMN_NAME,
            DATA_TYPE
        FROM COMPLIANCE_AI_DEMO.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'CUSTOMER_DATA'
          AND TABLE_NAME IN ('NASABAH','REKENING','KARTU_KREDIT','TRANSAKSI','LOAN_APPLICATION')
    ),
    classified AS (
        SELECT 
            c.TABLE_NAME,
            c.COLUMN_NAME,
            c.DATA_TYPE,
            '' AS SAMPLE_VALUES,
            SNOWFLAKE.CORTEX.COMPLETE(
                'claude-4-sonnet',
                'Kamu adalah AI classifier untuk data perbankan Indonesia. Klasifikasikan kolom database berikut.

Tabel: ' || c.TABLE_NAME || '
Kolom: ' || c.COLUMN_NAME || '
Tipe Data: ' || c.DATA_TYPE || '

Berikan respons HANYA dalam format JSON (tanpa markdown, tanpa backtick):
{"classification":"<IDENTIFIER|QUASI_IDENTIFIER|FINANCIAL|SENSITIVE|NON_SENSITIVE>","sensitivity":"<CRITICAL|HIGH|MEDIUM|LOW>","needs_masking":<true|false>,"needs_tag":<true|false>,"risk_level":"<CRITICAL|HIGH|MEDIUM|LOW>","reason":"<penjelasan singkat dalam bahasa Indonesia max 20 kata>"}'
            ) AS ai_response
        FROM column_info c
    )
    SELECT 
        TABLE_NAME,
        COLUMN_NAME,
        DATA_TYPE,
        SAMPLE_VALUES,
        TRIM(PARSE_JSON(ai_response):classification::VARCHAR) AS AI_CLASSIFICATION,
        TRIM(PARSE_JSON(ai_response):sensitivity::VARCHAR) AS AI_SENSITIVITY,
        PARSE_JSON(ai_response):needs_masking::BOOLEAN AS NEEDS_MASKING,
        PARSE_JSON(ai_response):needs_tag::BOOLEAN AS NEEDS_TAG,
        TRIM(PARSE_JSON(ai_response):risk_level::VARCHAR) AS RISK_LEVEL,
        TRIM(PARSE_JSON(ai_response):reason::VARCHAR) AS AI_REASON
    FROM classified;
    
    RETURN 'AI Classification completed. ' || (SELECT COUNT(*) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION) || ' columns classified.';
END;
$$;

-- 4b. Lihat data sample terlebih dahulu (untuk demo: tunjukkan data sebelum analysis)
SELECT * FROM COMPLIANCE_AI_DEMO.CUSTOMER_DATA.NASABAH LIMIT 5;
SELECT * FROM COMPLIANCE_AI_DEMO.CUSTOMER_DATA.KARTU_KREDIT LIMIT 5;
SELECT * FROM COMPLIANCE_AI_DEMO.CUSTOMER_DATA.REKENING LIMIT 5;
SELECT * FROM COMPLIANCE_AI_DEMO.CUSTOMER_DATA.TRANSAKSI LIMIT 5;
SELECT * FROM COMPLIANCE_AI_DEMO.CUSTOMER_DATA.LOAN_APPLICATION LIMIT 5;

-- 4c. Jalankan AI Classification
CALL COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_AI_CLASSIFY_COLUMNS();

-- 4c. Lihat hasil klasifikasi
SELECT TABLE_NAME, COLUMN_NAME, AI_CLASSIFICATION, AI_SENSITIVITY, 
       NEEDS_MASKING, NEEDS_TAG, RISK_LEVEL, AI_REASON 
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION 
ORDER BY CASE RISK_LEVEL WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END;

-- 4d. Summary: kolom yang butuh masking
SELECT TABLE_NAME, COUNT(*) AS TOTAL_COLUMNS, 
       SUM(CASE WHEN NEEDS_MASKING THEN 1 ELSE 0 END) AS NEEDS_MASKING,
       SUM(CASE WHEN NEEDS_TAG THEN 1 ELSE 0 END) AS NEEDS_TAG
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION
GROUP BY TABLE_NAME ORDER BY TABLE_NAME;

-- ============================================================================
-- STEP 4e: AI VALUE-LEVEL AUDIT (Deep Data Inspection)
-- Feature: Cortex COMPLETE - AI inspects ACTUAL VALUES to determine protection
-- ============================================================================
-- Berbeda dengan Step 4 (metadata-only classification), step ini:
--   1. Men-SAMPLE nilai aktual dari setiap kolom sensitif (5 baris)
--   2. Mengirim sample ke Cortex LLM untuk analisis
--   3. AI menentukan apakah data masih PLAIN_TEXT atau sudah HASHED/MASKED/ENCRYPTED
--   4. Menghilangkan false positive (kolom dilaporkan violation padahal sudah di-hash dari source)
-- ============================================================================

-- 4e-i. Buat Stored Procedure Value-Level Audit
CREATE OR REPLACE PROCEDURE COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_AI_VALUE_LEVEL_AUDIT()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    -- ================================================================
    -- SP_AI_VALUE_LEVEL_AUDIT - Deep Data Protection Inspection
    --
    -- Menggunakan Cortex LLM untuk menganalisis NILAI AKTUAL dari
    -- kolom-kolom sensitif dan menentukan apakah data sudah terproteksi
    -- (hashed, masked, encrypted, tokenized) atau masih plain text.
    -- ================================================================

    -- Recreate hasil tabel
    CREATE OR REPLACE TABLE COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT (
        TABLE_NAME VARCHAR(100),
        COLUMN_NAME VARCHAR(100),
        AI_CLASSIFICATION VARCHAR(50),
        RISK_LEVEL VARCHAR(20),
        SAMPLE_VALUES TEXT,
        PROTECTION_STATUS VARCHAR(30),
        CONFIDENCE VARCHAR(10),
        PATTERN_DETECTED TEXT,
        IS_PROTECTED BOOLEAN,
        AI_RECOMMENDATION TEXT,
        AUDITED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
    );

    -- ================================================================
    -- Loop per tabel: dynamic sample → LLM analysis → flatten → insert
    -- ================================================================
    LET tables_done INTEGER := 0;

    -- Cursor: daftar tabel yang punya kolom sensitif
    LET tbl_cursor CURSOR FOR
        SELECT DISTINCT TABLE_NAME 
        FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION
        WHERE RISK_LEVEL IN ('CRITICAL','HIGH')
        ORDER BY TABLE_NAME;

    FOR tbl_rec IN tbl_cursor DO
        LET current_table VARCHAR := tbl_rec.TABLE_NAME;

        -- Step A: Build dynamic SQL untuk sampling kolom sensitif
        LET sample_query VARCHAR;
        SELECT LISTAGG(
            'SELECT ''' || COLUMN_NAME || ''' AS col_name, ''' || COLUMN_NAME || ': '' || ARRAY_TO_STRING(ARRAY_AGG(' || COLUMN_NAME || '::VARCHAR), '', '') AS col_sample FROM (SELECT ' || COLUMN_NAME || ' FROM COMPLIANCE_AI_DEMO.CUSTOMER_DATA.' || TABLE_NAME || ' LIMIT 5)',
            ' UNION ALL '
        ) WITHIN GROUP (ORDER BY COLUMN_NAME) 
        INTO :sample_query
        FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION
        WHERE TABLE_NAME = :current_table AND RISK_LEVEL IN ('CRITICAL','HIGH');

        -- Step B: Execute dynamic SQL → gabung semua sample jadi satu string
        LET full_query VARCHAR := 'SELECT LISTAGG(col_sample, ''\n'') WITHIN GROUP (ORDER BY col_name) AS all_samples FROM (' || :sample_query || ')';
        
        LET sample_result VARCHAR := '';
        LET res RESULTSET := (EXECUTE IMMEDIATE :full_query);
        LET c CURSOR FOR res;
        FOR row_var IN c DO
            sample_result := row_var.ALL_SAMPLES;
        END FOR;

        -- Step C: Build classification context (kolom + tipe + AI classification)
        LET col_context VARCHAR;
        SELECT LISTAGG(
            COLUMN_NAME || ' (tipe=' || DATA_TYPE || ', klasifikasi=' || AI_CLASSIFICATION || ', risk=' || RISK_LEVEL || ')',
            '\n'
        ) WITHIN GROUP (ORDER BY COLUMN_NAME)
        INTO :col_context
        FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION
        WHERE TABLE_NAME = :current_table AND RISK_LEVEL IN ('CRITICAL','HIGH');

        -- Step D: Kirim ke Cortex LLM untuk analisis value-level
        CREATE OR REPLACE TEMPORARY TABLE _tmp_value_audit_response AS
        SELECT SNOWFLAKE.CORTEX.COMPLETE(
            'claude-4-sonnet',
            'Kamu adalah Data Protection Auditor untuk bank Indonesia. Tugasmu: menganalisis SAMPLE VALUES dari kolom-kolom database untuk menentukan apakah data sudah terproteksi atau masih plain text.

== TABEL: ' || :current_table || ' ==

== METADATA KOLOM (nama, tipe, klasifikasi AI, risk level) ==
' || :col_context || '

== SAMPLE VALUES (5 baris per kolom) ==
' || :sample_result || '

== INSTRUKSI ==
Untuk SETIAP kolom di atas, analisis sample values-nya dan tentukan:

1. protection_status - WAJIB salah satu dari:
   - PLAIN_TEXT: Data asli, bisa dibaca langsung (nama orang, nomor telepon valid, NIK 16 digit, email valid, alamat jelas, dll)
   - HASHED: Data sudah di-hash (hex string panjang 32/40/64 karakter, contoh: a1b2c3d4e5...)
   - MASKED: Data sudah di-mask sebagian (contoh: 0812****7890, ****-****-****-1234, nama: B*** S***)
   - ENCRYPTED: Data sudah di-enkripsi (base64 panjang, binary-like string)
   - TOKENIZED: Data sudah di-tokenize (format/panjang berbeda dari aslinya, UUID sebagai pengganti)
   - REDACTED: Data sudah dihapus/diganti placeholder (contoh: [REDACTED], N/A, XXX)

2. confidence: HIGH, MEDIUM, atau LOW

3. pattern_detected: Jelaskan secara spesifik pola apa yang kamu temukan di sample values. 
   Contoh: "Nomor telepon Indonesia valid format +62xxx", "String hex 64 karakter (kemungkinan SHA-256)", "Email valid dengan domain", dll.

4. is_protected: true jika data SUDAH terproteksi (bukan PLAIN_TEXT), false jika masih PLAIN_TEXT

5. recommendation: Jika is_protected=false, berikan rekomendasi spesifik. Jika is_protected=true, tulis "Data sudah terproteksi di level nilai."

PENTING:
- Nomor seperti 3170000000000000 (16 digit dimulai 31/32/33/34/35/36) adalah NIK Indonesia → PLAIN_TEXT
- Nomor seperti +6281xxx atau 081xxx adalah nomor telepon Indonesia → PLAIN_TEXT
- Angka numerik biasa (saldo, pendapatan) → PLAIN_TEXT (kecuali terlihat sudah di-hash)
- Alamat yang bisa dibaca (Jl. Sudirman No. 1, Jakarta) → PLAIN_TEXT
- Nama orang yang bisa dibaca (Budi Santoso) → PLAIN_TEXT
- CUSTOMER_ID, REKENING_ID, APPLICATION_ID, TRANSAKSI_ID: jika formatnya adalah ID internal sistem (CUST-000001, TRX-000001) → ini IDENTIFIER INTERNAL, bukan data sensitif yang perlu di-hash. Set protection_status=IDENTIFIER_INTERNAL dan is_protected=true.

Kembalikan HANYA valid JSON array (tanpa markdown, tanpa backtick, tanpa penjelasan):
[{"column_name":"...","protection_status":"...","confidence":"...","pattern_detected":"...","is_protected":<true|false>,"recommendation":"..."},...]'
        ) AS LLM_RESPONSE;

        -- Step E: Flatten ke temp table dulu, baru JOIN dengan AI_CLASSIFICATION
        CREATE OR REPLACE TEMPORARY TABLE _tmp_flattened_audit AS
        SELECT 
            f.value:column_name::VARCHAR AS COLUMN_NAME,
            f.value:protection_status::VARCHAR AS PROTECTION_STATUS,
            f.value:confidence::VARCHAR AS CONFIDENCE,
            f.value:pattern_detected::VARCHAR AS PATTERN_DETECTED,
            f.value:is_protected::BOOLEAN AS IS_PROTECTED,
            f.value:recommendation::VARCHAR AS AI_RECOMMENDATION
        FROM _tmp_value_audit_response,
            LATERAL FLATTEN(input => TRY_PARSE_JSON(LLM_RESPONSE)) f
        WHERE TRY_PARSE_JSON(LLM_RESPONSE) IS NOT NULL;

        INSERT INTO COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT
            (TABLE_NAME, COLUMN_NAME, AI_CLASSIFICATION, RISK_LEVEL, SAMPLE_VALUES,
             PROTECTION_STATUS, CONFIDENCE, PATTERN_DETECTED, IS_PROTECTED, AI_RECOMMENDATION)
        SELECT 
            :current_table,
            fa.COLUMN_NAME,
            ac.AI_CLASSIFICATION,
            ac.RISK_LEVEL,
            :sample_result,
            fa.PROTECTION_STATUS,
            fa.CONFIDENCE,
            fa.PATTERN_DETECTED,
            fa.IS_PROTECTED,
            fa.AI_RECOMMENDATION
        FROM _tmp_flattened_audit fa
        LEFT JOIN COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.AI_CLASSIFICATION ac
            ON ac.TABLE_NAME = :current_table AND ac.COLUMN_NAME = fa.COLUMN_NAME;

        tables_done := tables_done + 1;
    END FOR;

    -- ================================================================
    -- Cleanup
    -- ================================================================
    DROP TABLE IF EXISTS _tmp_value_audit_response;
    DROP TABLE IF EXISTS _tmp_flattened_audit;

    LET total_cols INTEGER := (SELECT COUNT(*) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT);
    LET plain_text_count INTEGER := (SELECT COUNT(*) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT WHERE PROTECTION_STATUS = 'PLAIN_TEXT');
    LET protected_count INTEGER := (SELECT COUNT(*) FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT WHERE IS_PROTECTED = TRUE);

    RETURN 'Value-Level Audit completed. ' || :total_cols || ' columns audited across ' || :tables_done || ' tables. ' ||
           :plain_text_count || ' columns still PLAIN_TEXT, ' || :protected_count || ' columns already protected.';
END;
$$;

-- 4e-ii. Buat View Summary
CREATE OR REPLACE VIEW COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_VALUE_AUDIT_SUMMARY AS
SELECT 
    TABLE_NAME,
    COUNT(*) AS TOTAL_SENSITIVE_COLUMNS,
    SUM(CASE WHEN PROTECTION_STATUS = 'PLAIN_TEXT' THEN 1 ELSE 0 END) AS PLAIN_TEXT_COLUMNS,
    SUM(CASE WHEN IS_PROTECTED = TRUE THEN 1 ELSE 0 END) AS PROTECTED_COLUMNS,
    ROUND(SUM(CASE WHEN IS_PROTECTED = TRUE THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS PROTECTION_SCORE_PCT
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT
GROUP BY TABLE_NAME
ORDER BY PROTECTION_SCORE_PCT ASC;

-- 4e-iii. Jalankan Value-Level Audit (~30 detik, 5 LLM calls - 1 per tabel)
CALL COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_AI_VALUE_LEVEL_AUDIT();

-- 4e-iv. Lihat hasil: status proteksi per kolom
SELECT TABLE_NAME, COLUMN_NAME, AI_CLASSIFICATION, RISK_LEVEL,
       PROTECTION_STATUS, CONFIDENCE, IS_PROTECTED, PATTERN_DETECTED
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT
ORDER BY IS_PROTECTED ASC, RISK_LEVEL DESC;

-- 4e-v. Summary per tabel: berapa persen kolom sudah terproteksi?
SELECT * FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.V_VALUE_AUDIT_SUMMARY;

-- 4e-vi. ALERT: Kolom CRITICAL/HIGH yang masih PLAIN_TEXT (butuh tindakan segera!)
SELECT TABLE_NAME, COLUMN_NAME, AI_CLASSIFICATION, RISK_LEVEL, 
       PROTECTION_STATUS, PATTERN_DETECTED, AI_RECOMMENDATION
FROM COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.VALUE_LEVEL_AUDIT
WHERE PROTECTION_STATUS = 'PLAIN_TEXT' AND RISK_LEVEL IN ('CRITICAL','HIGH')
ORDER BY CASE RISK_LEVEL WHEN 'CRITICAL' THEN 1 ELSE 2 END;
