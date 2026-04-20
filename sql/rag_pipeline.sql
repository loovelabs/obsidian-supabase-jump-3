-- ============================================================================
-- LOOVE OS RAG Pipeline: Automatic Embeddings for vault_files
-- ============================================================================
-- Purpose: Extend the vault_files table with pgvector embeddings and
--          configure automatic embedding generation using Supabase's
--          native pgmq + pg_cron + Edge Function pattern.
--
-- Status: DESIGNED, NOT YET DEPLOYED
-- Requires: vault_files table, translation layer triggers (translation_layer.sql)
-- Reference: https://supabase.com/docs/guides/ai/automatic-embeddings
--
-- This pipeline enables:
--   1. Automatic embedding generation when vault_files rows are created/updated
--   2. Semantic search across ALL operational data via a single SQL function
--   3. Cross-domain knowledge retrieval for agents and human users
--   4. Integration with OB1's existing embedding column on loove_index_entries
-- ============================================================================

-- ── Step 1: Enable Required Extensions ──────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA extensions;

-- ── Step 2: Add Embedding Column to vault_files ─────────────────────────────

ALTER TABLE vault_files
  ADD COLUMN IF NOT EXISTS embedding vector(384);
  -- 384 dimensions = gte-small model (Supabase's built-in model)
  -- Alternative: 1536 for text-embedding-3-small, 3072 for text-embedding-3-large

CREATE INDEX IF NOT EXISTS vault_files_embedding_idx
  ON vault_files
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);
  -- IVFFlat is appropriate for <100k rows. Switch to HNSW for larger datasets.

-- ── Step 3: Create Utility Schema and Functions ─────────────────────────────

CREATE SCHEMA IF NOT EXISTS util;

-- Retrieve project URL from Vault (required for Edge Function invocation)
CREATE OR REPLACE FUNCTION util.project_url()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  secret_value text;
BEGIN
  SELECT decrypted_secret INTO secret_value
    FROM vault.decrypted_secrets
    WHERE name = 'project_url';
  RETURN secret_value;
END;
$$;

-- Generic Edge Function invoker
CREATE OR REPLACE FUNCTION util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds int = 5 * 60 * 1000
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  headers_raw text;
  auth_header text;
BEGIN
  headers_raw := current_setting('request.headers', true);
  auth_header := CASE
    WHEN headers_raw IS NOT NULL THEN
      (headers_raw::json->>'authorization')
    ELSE NULL
  END;

  PERFORM net.http_post(
    url => util.project_url() || '/functions/v1/' || name,
    headers => jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', auth_header
    ),
    body => body,
    timeout_milliseconds => timeout_milliseconds
  );
END;
$$;

-- ── Step 4: Create Embedding Queue ──────────────────────────────────────────

SELECT pgmq.create('embedding_jobs');

-- ── Step 5: Trigger to Enqueue Embedding Jobs ───────────────────────────────

CREATE OR REPLACE FUNCTION loove_enqueue_embedding()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Only enqueue for non-binary, non-deleted files with content
  IF NEW.is_binary = true OR NEW.deleted = true OR NEW.content IS NULL THEN
    RETURN NEW;
  END IF;

  -- Clear the existing embedding when content changes
  IF TG_OP = 'UPDATE' AND OLD.content IS DISTINCT FROM NEW.content THEN
    NEW.embedding := NULL;
  END IF;

  -- Enqueue the embedding job
  PERFORM pgmq.send(
    'embedding_jobs',
    jsonb_build_object(
      'id', NEW.id,
      'table', 'vault_files',
      'content_column', 'content',
      'embedding_column', 'embedding'
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_vault_embedding ON vault_files;
CREATE TRIGGER trg_enqueue_vault_embedding
  BEFORE INSERT OR UPDATE OF content ON vault_files
  FOR EACH ROW
  EXECUTE FUNCTION loove_enqueue_embedding();

-- ── Step 6: Cron Job to Process Embedding Queue ─────────────────────────────
-- Runs every 30 seconds, invokes the Edge Function to process queued jobs.

SELECT cron.schedule(
  'process-embedding-queue',
  '30 seconds',
  $$
    SELECT util.invoke_edge_function(
      'generate-embedding',
      jsonb_build_object('queue', 'embedding_jobs', 'batch_size', 10)
    );
  $$
);

-- ── Step 7: Semantic Search Function ────────────────────────────────────────
-- Unified search across vault_files (which contains projections of all
-- operational tables via the translation layer).

CREATE OR REPLACE FUNCTION loove_semantic_search(
  p_query_embedding vector(384),
  p_match_threshold float DEFAULT 0.7,
  p_match_count int DEFAULT 10,
  p_filter_tags text[] DEFAULT NULL,
  p_filter_source_table text DEFAULT NULL
)
RETURNS TABLE (
  id text,
  path text,
  content text,
  similarity float,
  tags text[],
  source_table text,
  source_id text,
  frontmatter jsonb
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT
    vf.id,
    vf.path,
    vf.content,
    1 - (vf.embedding <=> p_query_embedding) AS similarity,
    vf.tags,
    vf.frontmatter->>'source_table' AS source_table,
    vf.frontmatter->>'source_id' AS source_id,
    vf.frontmatter
  FROM vault_files vf
  WHERE
    vf.deleted = false
    AND vf.embedding IS NOT NULL
    AND 1 - (vf.embedding <=> p_query_embedding) > p_match_threshold
    AND (p_filter_tags IS NULL OR vf.tags && p_filter_tags)
    AND (p_filter_source_table IS NULL
         OR vf.frontmatter->>'source_table' = p_filter_source_table)
  ORDER BY vf.embedding <=> p_query_embedding
  LIMIT p_match_count;
END;
$$;

-- ── Step 8: Cross-Table Search (vault_files + loove_index_entries) ───────────
-- OB1's loove_index_entries already has embeddings. This function searches
-- BOTH tables for maximum coverage.

CREATE OR REPLACE FUNCTION loove_unified_search(
  p_query_embedding vector(384),
  p_match_threshold float DEFAULT 0.7,
  p_match_count int DEFAULT 10
)
RETURNS TABLE (
  source text,
  id text,
  title text,
  content_preview text,
  similarity float,
  tags text[],
  metadata jsonb
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  (
    -- Search vault_files (translated operational data + user notes)
    SELECT
      'vault_files'::text AS source,
      vf.id,
      split_part(vf.path, '/', -1) AS title,
      left(vf.content, 500) AS content_preview,
      1 - (vf.embedding <=> p_query_embedding) AS similarity,
      vf.tags,
      vf.frontmatter AS metadata
    FROM vault_files vf
    WHERE
      vf.deleted = false
      AND vf.embedding IS NOT NULL
      AND 1 - (vf.embedding <=> p_query_embedding) > p_match_threshold
  )
  UNION ALL
  (
    -- Search loove_index_entries (OB1 knowledge layer)
    SELECT
      'loove_index_entries'::text AS source,
      lie.id::text,
      COALESCE(lie.description, lie.feature_name, 'Untitled') AS title,
      lie.content_preview,
      1 - (lie.embedding <=> p_query_embedding) AS similarity,
      lie.tags,
      jsonb_build_object(
        'domain_id', lie.domain_id,
        'category', lie.category,
        'entry_type', lie.entry_type,
        'status', lie.status
      ) AS metadata
    FROM loove_index_entries lie
    WHERE
      lie.embedding IS NOT NULL
      AND 1 - (lie.embedding <=> p_query_embedding) > p_match_threshold
  )
  ORDER BY similarity DESC
  LIMIT p_match_count;
END;
$$;

-- ============================================================================
-- EDGE FUNCTION: generate-embedding
-- ============================================================================
-- This Edge Function must be deployed to Supabase. It:
--   1. Reads batch_size messages from the embedding_jobs queue
--   2. For each job, fetches the content from the specified table/column
--   3. Generates an embedding using Supabase AI (gte-small) or OpenAI
--   4. Updates the row with the generated embedding
--   5. Acknowledges the message in the queue
--
-- The Edge Function code is provided separately in:
--   artifacts/generate-embedding/index.ts
-- ============================================================================
