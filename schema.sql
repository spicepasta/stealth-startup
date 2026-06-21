-- ============================================================
-- ClassicScroll — Supabase / Postgres schema  (taxonomy v1)
-- ============================================================
-- Run this entire file once in the Supabase SQL Editor.
-- It is idempotent: safe to re-run (uses IF NOT EXISTS / OR REPLACE).
--
-- After running:
--   • Copy your Supabase project URL + anon key into index.html
--   • Copy your Supabase project URL + service-role key into pipeline.py
--   • NEVER put the service-role key in the browser
-- ============================================================


-- ─── CANONICAL TAXONOMY HELPER ───────────────────────────────────────────────
-- This function is the single source of truth for valid vibe-tag strings.
-- Any change here MUST be mirrored byte-for-byte in:
--   • pipeline.py  → TAXONOMY list and VibeTag Literal type
--   • index.html   → const TAXONOMY array
-- When the list changes, bump taxonomy_version to "v2" in pipeline.py so we
-- know exactly which rows need re-tagging without guessing.
CREATE OR REPLACE FUNCTION public.is_valid_vibe_tags(tags text[])
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  -- <@ means "is contained by": every element of tags must be in the RHS array.
  -- Sorted alphabetically to make audits easy; order does not affect semantics.
  SELECT tags <@ ARRAY[
    'adventure',
    'class-conflict',
    'coming-of-age',
    'existential',
    'family-drama',
    'gothic',
    'horror',
    'humor',
    'mystery',
    'nature',
    'philosophy',
    'psychological',
    'redemption',
    'revenge',
    'romance',
    'satire',
    'social-commentary',
    'supernatural',
    'tragedy',
    'war'
  ]::text[];
$$;


-- ─── TABLE: profiles ─────────────────────────────────────────────────────────
-- One row per auth.users row; created automatically by the trigger below.
-- favorite_tags is the user's chosen subset of the canonical taxonomy and
-- is the sole input to feed ranking (array-overlap score against vibe_tags).
CREATE TABLE IF NOT EXISTS public.profiles (
  id            uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  favorite_tags text[]      NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),

  -- Every selected tag must belong to the canonical taxonomy
  CONSTRAINT favorite_tags_valid_vibes
    CHECK (public.is_valid_vibe_tags(favorite_tags))
);


-- ─── TABLE: excerpts ─────────────────────────────────────────────────────────
-- Populated exclusively by pipeline.py via the service-role key (bypasses RLS).
-- Authenticated browser clients can SELECT but never INSERT / UPDATE / DELETE.
CREATE TABLE IF NOT EXISTS public.excerpts (
  id               uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  book_title       text         NOT NULL,
  author           text         NOT NULL,
  gutenberg_id     int          NOT NULL,
  body             text         NOT NULL,
  vibe_tags        text[]       NOT NULL DEFAULT '{}',
  descriptor_tags  text[]       NOT NULL DEFAULT '{}',  -- free-form, never used for ranking
  taxonomy_version text         NOT NULL DEFAULT 'v1',
  confidence       numeric(4,3) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  created_at       timestamptz  NOT NULL DEFAULT now(),

  -- All vibe_tags must be drawn from the canonical taxonomy
  CONSTRAINT vibe_tags_valid_taxonomy
    CHECK (public.is_valid_vibe_tags(vibe_tags)),

  -- Pydantic schema enforces 3–5 tags; DB constraint is the safety net
  -- cardinality() returns 0 for empty arrays (not NULL), so this rejects '{}'
  CONSTRAINT vibe_tags_count
    CHECK (cardinality(vibe_tags) BETWEEN 3 AND 5)
);

-- GIN index enables fast array-overlap (&&) queries used by get_feed_for_user.
-- As the excerpts table grows, this keeps tag-matching sub-millisecond.
CREATE INDEX IF NOT EXISTS excerpts_vibe_tags_gin
  ON public.excerpts USING GIN (vibe_tags);


-- ─── TABLE: interactions ─────────────────────────────────────────────────────
-- One row per (user, excerpt, action).
-- The UNIQUE constraint on (user_id, excerpt_id, action) makes like/bookmark
-- idempotent: a second like upserts rather than inserting a duplicate row.
CREATE TABLE IF NOT EXISTS public.interactions (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        NOT NULL REFERENCES auth.users(id)      ON DELETE CASCADE,
  excerpt_id       uuid        NOT NULL REFERENCES public.excerpts(id) ON DELETE CASCADE,
  action           text        NOT NULL CHECK (action IN ('like', 'bookmark', 'view')),
  view_duration_ms int,        -- milliseconds card was on screen; only set for action='view'
  created_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT interactions_unique_action
    UNIQUE (user_id, excerpt_id, action)
);


-- ─── TABLE: comments ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.comments (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES auth.users(id)      ON DELETE CASCADE,
  excerpt_id uuid        NOT NULL REFERENCES public.excerpts(id) ON DELETE CASCADE,
  body       text        NOT NULL CHECK (length(body) > 0 AND length(body) <= 1000),
  created_at timestamptz NOT NULL DEFAULT now()
);


-- ─── TRIGGER: auto-create profile on signup ──────────────────────────────────
-- Fires after every INSERT on auth.users (i.e., every new sign-up).
-- SECURITY DEFINER so the trigger runs as its owner and can insert into profiles
-- even before the new user has an authenticated session.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;  -- safe if the profile was created another way
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ─── ROW LEVEL SECURITY ──────────────────────────────────────────────────────
ALTER TABLE public.profiles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.excerpts     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments     ENABLE ROW LEVEL SECURITY;

-- profiles: users can only see and modify their own row
CREATE POLICY "profiles_select_own"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "profiles_insert_own"
  ON public.profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING  (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- excerpts: any authenticated user can read; no client-side writes
-- (pipeline.py uses the service-role key which bypasses RLS entirely)
CREATE POLICY "excerpts_select_authenticated"
  ON public.excerpts FOR SELECT
  USING (auth.role() = 'authenticated');

-- excerpts are public-domain literature, so the anon (publishable) key may also
-- read them.  This lets the local admin dashboard use the publishable key in the
-- browser instead of a secret key (new secret keys are blocked in browsers).
-- No write policy for anon: inserts still only happen via the service role.
CREATE POLICY "excerpts_select_anon"
  ON public.excerpts FOR SELECT
  TO anon
  USING (true);

-- interactions: users see and create only their own rows
CREATE POLICY "interactions_select_own"
  ON public.interactions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "interactions_insert_own"
  ON public.interactions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- comments: anyone authenticated can read; users manage only their own
CREATE POLICY "comments_select_authenticated"
  ON public.comments FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "comments_insert_own"
  ON public.comments FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "comments_update_own"
  ON public.comments FOR UPDATE
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "comments_delete_own"
  ON public.comments FOR DELETE
  USING (auth.uid() = user_id);


-- ─── TABLE-LEVEL GRANTS ──────────────────────────────────────────────────────
-- RLS policies decide which ROWS are visible; these grants decide which
-- OPERATIONS the authenticated role is even allowed to attempt.
GRANT SELECT, INSERT, UPDATE         ON public.profiles     TO authenticated;
GRANT SELECT                         ON public.excerpts     TO authenticated;
GRANT SELECT                         ON public.excerpts     TO anon;
GRANT SELECT, INSERT, UPDATE         ON public.interactions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.comments     TO authenticated;


-- ─── FEED FUNCTION ───────────────────────────────────────────────────────────
-- Called from the browser via: db.rpc('get_feed_for_user', { p_limit: 20 })
--
-- Algorithm:
--   1. Fetch the calling user's favorite_tags from profiles.
--   2. Collect excerpt IDs the user has already liked or viewed (anti-join).
--   3. For each unseen excerpt, count how many of its vibe_tags appear in
--      the user's favorite_tags → overlap_count.
--   4. Order by overlap_count DESC (personalized), then confidence DESC,
--      then newest first as a final tiebreak.
--   5. Return at most p_limit rows. When personalized stock is exhausted,
--      overlap=0 excerpts fill remaining slots so the feed never goes empty.
--
-- SECURITY DEFINER: runs as function owner so it can freely join profiles
-- and excerpts; the function itself enforces that it only exposes data for
-- auth.uid(), so it is safe to grant to authenticated.
CREATE OR REPLACE FUNCTION public.get_feed_for_user(p_limit int DEFAULT 20)
RETURNS TABLE (
  id               uuid,
  book_title       text,
  author           text,
  gutenberg_id     int,
  body             text,
  vibe_tags        text[],
  descriptor_tags  text[],
  taxonomy_version text,
  confidence       numeric,
  created_at       timestamptz,
  overlap_count    bigint
)
SECURITY DEFINER
SET search_path = public
LANGUAGE sql
AS $$
  WITH
  -- The calling user's preferred tags; empty array if profile not found
  user_tags AS (
    -- Unnest so each preferred tag is its own row; IN (subquery) then works cleanly
    SELECT unnest(COALESCE(favorite_tags, ARRAY[]::text[])) AS tag
    FROM public.profiles
    WHERE id = auth.uid()
  ),
  -- Excerpts this user has already engaged with (exclude from feed)
  seen_ids AS (
    SELECT excerpt_id
    FROM public.interactions
    WHERE user_id = auth.uid()
      AND action IN ('like', 'view')
  )
  SELECT
    e.id,
    e.book_title,
    e.author,
    e.gutenberg_id,
    e.body,
    e.vibe_tags,
    e.descriptor_tags,          -- returned for display only; never drives ranking
    e.taxonomy_version,
    e.confidence,
    e.created_at,
    -- Count of vibe_tags that overlap with the user's favorites
    (
      SELECT count(*)
      FROM unnest(e.vibe_tags) AS t(tag)
      WHERE t.tag IN (SELECT tag FROM user_tags)
    ) AS overlap_count
  FROM public.excerpts e
  WHERE e.id NOT IN (SELECT excerpt_id FROM seen_ids)
  ORDER BY
    overlap_count DESC,   -- most-relevant excerpts first
    e.confidence  DESC,   -- prefer higher-quality excerpts on ties
    e.created_at  DESC    -- newest as final tiebreak
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_feed_for_user(int) TO authenticated;
