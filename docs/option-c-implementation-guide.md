# Option C Implementation Guide: Obsidian + Supabase Native RAG

**Status:** DESIGNED, READY FOR DEPLOYMENT
**Architecture:** SupaBase Jump (forked) + Postgres Translation Layer + Supabase Automatic Embeddings

This document outlines the complete turnkey implementation plan for the Option C architecture. All necessary code artifacts have been generated and are attached.

## 1. Architecture Overview

This architecture eliminates the need for an external server, Obsidian Sync, or third-party RAG tools like TinyRAG. It operates entirely within the LOOVE Supabase infrastructure and the user's local Obsidian client.

1. **The Translation Layer:** Postgres triggers automatically project rows from operational tables (`shared_context`, `artists`, `openclaw_tasks`, etc.) into a central `vault_files` table as Markdown documents with YAML frontmatter.
2. **The Sync Layer:** A forked version of the SupaBase Jump plugin runs in the principal's local Obsidian client. It connects directly to the `vault_files` table via Supabase Realtime, syncing notes bidirectionally without a middleman server.
3. **The RAG Pipeline:** Supabase's native pgvector and Edge Functions automatically generate embeddings for every document in `vault_files`. This makes the entire knowledge base semantically searchable via SQL or API, directly integrating with the existing OB1 knowledge layer.

## 2. Deployment Steps

The deployment is blocked only by the pending PIPY token requisition for GitHub write access (required to fork the SupaBase Jump repository). Once approved, the deployment proceeds in four stages:

### Stage 1: Repository Fork & Modification
1. Fork `brianstm/obsidian-supabase-jump` to `loovelabs/obsidian-supabase-jump`.
2. Apply the modifications detailed in `fork_modifications.md` (primarily adding "system vault" awareness so the plugin can sync the translation layer notes).
3. Release v1.2.0-loove.

### Stage 2: Supabase Schema Setup
1. The principal installs the forked plugin in Obsidian and uses the "One-Click Setup" to create the base `vault_files` table and storage buckets.
2. Execute `translation_layer.sql` in the Supabase SQL Editor. This creates the triggers that project operational data into `vault_files`.
3. Run the backfill commands (commented at the bottom of `translation_layer.sql`) to populate the vault with existing data.

### Stage 3: RAG Pipeline Deployment
1. Execute `rag_pipeline.sql` in the Supabase SQL Editor. This adds the vector column, pgmq queues, and semantic search functions.
2. Deploy the embedding generation Edge Function:
   ```bash
   supabase functions deploy generate-embedding
   ```
3. The pg_cron job will automatically begin processing the queue, generating embeddings for all ~3,500 backfilled notes using Supabase's built-in AI inference.

### Stage 4: Obsidian Client Configuration
1. Disable Obsidian Sync for the LOOVE vault to prevent conflicts.
2. Configure the SupaBase Jump plugin with the system vault ID (`loove-system`).
3. Install community plugins for local RAG (e.g., Smart Connections) to enable AI chat directly over the synced vault.

## 3. Included Artifacts

The following artifacts have been generated and are ready for use:

1. **`translation_layer.sql`**: The complete Postgres SQL script containing triggers, frontmatter generators, and reverse-sync logic for 5 operational tables.
2. **`rag_pipeline.sql`**: The Supabase automatic embeddings setup, including pgvector configuration, pgmq queues, and the `loove_unified_search` function.
3. **`generate-embedding/index.ts`**: The Deno Edge Function that processes the embedding queue using the `gte-small` model.
4. **`fork_modifications.md`**: The specification for modifying the SupaBase Jump plugin to support LOOVE's system vault architecture.

## 4. Next Actions

I am currently waiting on PIPY token requisition `6ca673a9-6663-43f0-bffb-826351eb5fbc` to be approved at **loove.io/admin/token-requests**.

Once the token is approved, I can execute Stage 1 (the repository fork and modification) autonomously. If you prefer to fork the repository manually to `loovelabs/obsidian-supabase-jump`, please let me know, and I can proceed with the modifications immediately using the read-only PAT for cloning and a standard PR workflow.
