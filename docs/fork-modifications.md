# SupaBase Jump Fork Modifications for LOOVE OS

**Status:** DESIGNED, NOT YET IMPLEMENTED
**Source repo:** `brianstm/obsidian-supabase-jump`
**Target repo:** `loovelabs/obsidian-supabase-jump` (pending fork)

---

## 1. Why Fork

The upstream plugin is functional but carries maturity risk (single developer, 3 weeks old, no tests). Forking provides:

- Control over the codebase if the upstream is abandoned
- Ability to add LOOVE-specific features (system vault awareness, embedding status indicators)
- A stable installation target for the principal's Obsidian setup

The fork should track upstream via periodic rebases, not diverge permanently.

---

## 2. Modifications Required

### 2.1 System Vault Awareness (Priority: P1)

The translation layer generates notes under `vault_id = 'loove-system'`. The plugin currently scopes all operations to a single vault_id generated at setup. The fork needs to:

- Add a `systemVaultId` setting (default: `'loove-system'`)
- On sync, pull from BOTH the user's vault_id AND the system vault_id
- Mark system-generated notes as read-only in the Obsidian UI (or at minimum, visually distinguish them)
- When a system note is edited, allow the edit to propagate (the reverse sync trigger handles the rest)

**Files to modify:** `settings.ts` (add setting), `sync.ts` (modify `fullSync` and realtime subscription to include system vault)

### 2.2 Conflict Resolution Improvement (Priority: P2)

The upstream uses mtime-based conflict resolution outside CRDT sessions. For system-generated notes, the source table is always authoritative. The fork should:

- For notes with `frontmatter.source_table` set: always prefer the server version on conflict
- For user-created notes: keep the existing mtime-based behavior
- Log conflicts to a `sync_conflicts` table for audit

**Files to modify:** `sync.ts` (modify `handleConflict` logic)

### 2.3 Embedding Status Indicator (Priority: P3)

Add a status bar indicator showing how many vault_files rows are pending embedding generation. This gives the user visibility into the RAG pipeline's progress.

**Files to modify:** `main.ts` (add periodic query to count rows where `embedding IS NULL AND deleted = false`)

### 2.4 Test Suite (Priority: P2)

Add basic tests for the critical paths:
- Frontmatter parsing round-trip
- Row ID generation
- Sync conflict resolution logic
- System vault filtering

**New files:** `tests/` directory with Vitest configuration

---

## 3. Obsidian Sync Configuration

### 3.1 Existing Obsidian Account

The principal already has an Obsidian account. SupaBase Jump does NOT use Obsidian Sync — it replaces it with direct Supabase sync. The two sync mechanisms are independent:

- **Obsidian Sync** (paid): Syncs vault files between devices via Obsidian's servers
- **SupaBase Jump**: Syncs vault files between devices via your own Supabase instance

Using both simultaneously would create conflicts. The recommended configuration is:

- **Disable Obsidian Sync** for the LOOVE vault (or use a separate vault)
- **Enable SupaBase Jump** as the sole sync mechanism for the LOOVE knowledge base
- Keep Obsidian Sync active for personal/non-LOOVE vaults if desired

### 3.2 Vault Structure

Create a dedicated vault (or subfolder within an existing vault) for LOOVE content:

```
LOOVE Vault/
├── loove/                          ← System-generated (translation layer)
│   ├── shared-context/             ← shared_context table
│   ├── knowledge/                  ← loove_index_entries table
│   │   ├── d0/                     ← Domain 0 entries
│   │   ├── d1/                     ← Domain 1 entries
│   │   └── ...
│   ├── tasks/                      ← openclaw_tasks table
│   ├── artists/                    ← artists table
│   └── trouble-reports/            ← trouble_reports table
├── notes/                          ← User-created notes (manual)
├── templates/                      ← Note templates
└── .obsidian/                      ← Plugin configs, themes, etc.
```

### 3.3 Plugin Setup Steps

1. Install SupaBase Jump via BRAT (or from the forked repo)
2. Open plugin settings
3. Enter the LOOVE Supabase project URL: `https://ewlygzvnvqyvszdpwbww.supabase.co`
4. Enter the anon key (from loove-keys)
5. Enter the Supabase Management API PAT (for one-click schema setup)
6. Click "One-Click Setup" to create the vault_files table and storage bucket
7. Sign in with email/password (or create a Supabase auth user for the principal)
8. Set the system vault ID to `loove-system` in the fork's settings
9. Click "Sync Now" to pull all existing vault_files

### 3.4 Recommended Obsidian Plugins for RAG

Once the vault is syncing, install these community plugins for local RAG:

| Plugin | Purpose | Notes |
|--------|---------|-------|
| Smart Connections | Local semantic search + AI chat over vault | Uses local embeddings, no API key needed for search |
| Obsidian Copilot | AI assistant with vault context | Requires OpenAI API key for chat |
| Dataview | Query frontmatter as structured data | Perfect for dashboards: `TABLE source_table, status FROM "loove"` |
| Graph View (built-in) | Visual cross-reference map | Shows connections between notes via wiki-links |
| Templater | Template-based note creation | For standardized operational notes |

### 3.5 Wiki-Style Cross-References

The translation layer generates notes with deterministic paths. This enables wiki-style cross-references in Obsidian:

- Link to a task: `[[loove/tasks/TASK-001]]`
- Link to an artist: `[[loove/artists/artist-handle]]`
- Link to a knowledge entry: `[[loove/knowledge/d1/entry-uuid]]`

For human-readable links, use Obsidian aliases: `[[loove/artists/artist-handle|Artist Display Name]]`

---

## 4. Mobile Configuration

SupaBase Jump supports mobile Obsidian. The same plugin settings apply. The principal can:

1. Install Obsidian on iOS/Android
2. Create the same vault name
3. Install SupaBase Jump via BRAT
4. Enter the same Supabase credentials
5. The vault syncs automatically via Supabase Realtime

No Obsidian Sync subscription is needed for mobile sync.
