-- ============================================================================
-- LOOVE OS: System Vault RLS Policy
-- ============================================================================
-- Adds a read-only RLS policy for system-generated vault notes.
-- This allows authenticated users to READ notes from the 'loove-system' vault
-- without requiring a matching user_id (since system notes have no user_id).
--
-- The translation layer triggers use SECURITY DEFINER and bypass RLS for writes.
-- This policy only enables client-side reads via the SupaBase Jump plugin.
-- ============================================================================

-- Allow any authenticated user to SELECT system vault notes (read-only)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'vault_files'
    AND policyname = 'Authenticated users can read system vault'
  ) THEN
    CREATE POLICY "Authenticated users can read system vault"
      ON vault_files
      FOR SELECT
      USING (vault_id = 'loove-system' AND auth.role() = 'authenticated');
  END IF;
END $$;

-- Allow authenticated users to UPDATE system vault notes (for reverse sync --
-- when users edit a system note in Obsidian, the plugin pushes the change
-- to vault_files, which triggers the reverse sync back to the source table).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'vault_files'
    AND policyname = 'Authenticated users can update system vault'
  ) THEN
    CREATE POLICY "Authenticated users can update system vault"
      ON vault_files
      FOR UPDATE
      USING (vault_id = 'loove-system' AND auth.role() = 'authenticated')
      WITH CHECK (vault_id = 'loove-system' AND auth.role() = 'authenticated');
  END IF;
END $$;

-- Subscribe system vault to Realtime (if not already)
-- This ensures the plugin receives live updates for system-generated notes
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'vault_files'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE vault_files;
  END IF;
END $$;
