-- =====================================================================
--  ENTREPOT MPD  -  01. Schema
--  Spotify Million Playlist Dataset -> modele en etoile PostgreSQL 16
--
--  Chaque choix de type ci-dessous est justifie par le profilage
--  exhaustif des 66 346 428 lignes sources (cf. COMMENT ON).
-- =====================================================================

-- --- Reglages portes par la BASE uniquement (le serveur reste intact) ---
ALTER DATABASE mpd SET max_parallel_workers_per_gather = 4;
ALTER DATABASE mpd SET work_mem                        = '256MB';
ALTER DATABASE mpd SET effective_cache_size            = '8GB';
ALTER DATABASE mpd SET random_page_cost                = 1.1;   -- SSD
-- effective_io_concurrency indisponible sur macOS (pas de posix_fadvise)

CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- recherche par sous-chaine
CREATE EXTENSION IF NOT EXISTS unaccent;   -- "Beyonce" doit trouver "Beyonce" accentue
CREATE EXTENSION IF NOT EXISTS btree_gin;

CREATE SCHEMA IF NOT EXISTS staging;

-- unaccent() est STABLE : inutilisable dans un index ou une colonne generee.
-- La forme a 2 arguments, dictionnaire explicite, est elle IMMUTABLE.
CREATE OR REPLACE FUNCTION public.f_unaccent(text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS
$$ SELECT public.unaccent('public.unaccent', $1) $$;

-- Normalisation de recherche : sans accent, en minuscules, espaces de bord
-- retires (70 011 noms de playlist en comportent).
CREATE OR REPLACE FUNCTION public.norm(text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS
$$ SELECT lower(public.f_unaccent(btrim($1))) $$;


-- =====================================================================
--  DIMENSIONS
-- =====================================================================

-- --- Artiste : 295 860 lignes -------------------------------------------------
CREATE TABLE dim_artist (
    artist_sk    integer     PRIMARY KEY,            -- cle de substitution dense
    artist_id    varchar(22) NOT NULL UNIQUE,        -- base62 Spotify, tjrs 22 car.
    artist_name  text        NOT NULL,               -- max mesure : 326 caracteres
    artist_name_norm text GENERATED ALWAYS AS (public.norm(artist_name)) STORED
);
COMMENT ON TABLE  dim_artist IS 'Artiste principal d''une piste. 295 860 lignes.';
COMMENT ON COLUMN dim_artist.artist_id IS
  'Identifiant Spotify sans le prefixe "spotify:artist:". Verifie : 22 caracteres base62 [0-9a-zA-Z] sur 100% des lignes.';
COMMENT ON COLUMN dim_artist.artist_name IS
  'Un artist_id porte toujours le meme nom (0 divergence sur 66 M lignes) : la cle determine bien l''attribut.';

-- --- Album : 734 684 lignes ---------------------------------------------------
-- PIEGE : 23 979 albums portent des pistes de PLUSIEURS artistes (compilations,
-- BO, "Various Artists"). L'album n'est donc PAS un enfant de l'artiste :
-- aucune FK artiste ici, sous peine de perdre 3,3 % des albums.
CREATE TABLE dim_album (
    album_sk     integer     PRIMARY KEY,
    album_id     varchar(22) NOT NULL UNIQUE,
    album_name   text        NOT NULL,               -- max mesure : 286 caracteres
    album_name_norm text GENERATED ALWAYS AS (public.norm(album_name)) STORED
);
COMMENT ON TABLE dim_album IS
  'Album. 734 684 lignes. Volontairement SANS cle artiste : 23 979 albums referencent plusieurs artistes (compilations).';

-- --- Piste : 2 262 292 lignes -------------------------------------------------
CREATE TABLE dim_track (
    track_sk     integer     PRIMARY KEY,
    track_id     varchar(22) NOT NULL UNIQUE,
    track_name   text        NOT NULL,               -- max mesure : 332 caracteres
    artist_sk    integer     NOT NULL REFERENCES dim_artist(artist_sk),
    album_sk     integer     NOT NULL REFERENCES dim_album(album_sk),
    duration_ms  integer     NOT NULL,
    track_name_norm text GENERATED ALWAYS AS (public.norm(track_name)) STORED,
    CONSTRAINT ck_track_duration CHECK (duration_ms >= -1)
);
COMMENT ON TABLE dim_track IS
  'Piste Spotify. 2 262 292 lignes. track_id determine strictement (nom, artiste, album, duree) : 0 divergence constatee.';
COMMENT ON COLUMN dim_track.duration_ms IS
  'ANOMALIE SOURCE : la piste spotify:track:1ms3hLP7f2mLlSzCuxwv1C ("Smash 3 - Scary Halloween Sound Effects") vaut -1. '
  'Valeur conservee par fidelite a la source, d''ou le CHECK >= -1 et non >= 0. '
  '1 086 lignes-pistes valent 0 ms. Filtrer duration_ms > 0 pour tout calcul de duree.';

-- --- Playlist : 1 000 000 lignes ----------------------------------------------
CREATE TABLE dim_playlist (
    playlist_id     integer     PRIMARY KEY,   -- "pid" natif, deja dense 0..999999
    name            text        NOT NULL,
    description     text,                      -- NULL = clef absente (981 240 cas)
    collaborative   boolean     NOT NULL,      -- source : chaine "true"/"false"
    modified_at     date        NOT NULL,      -- epoch source TOUJOURS aligne minuit UTC
    num_tracks      smallint    NOT NULL,      -- max 376
    num_albums      smallint    NOT NULL,      -- max 244
    num_artists     smallint    NOT NULL,      -- max 238
    num_edits       smallint    NOT NULL,      -- max 201
    num_followers   integer     NOT NULL,      -- max 71 643 -> DEPASSE smallint
    duration_ms     bigint      NOT NULL,      -- max 635 073 792
    name_norm       text GENERATED ALWAYS AS (public.norm(name)) STORED,
    CONSTRAINT ck_pl_counts CHECK (num_tracks BETWEEN 1 AND 1000)
);
COMMENT ON TABLE dim_playlist IS 'Playlist utilisateur. 1 000 000 lignes, playlist_id dense 0..999999.';
COMMENT ON COLUMN dim_playlist.description IS
  'NULL = champ absent du JSON (981 240 playlists). 18 760 playlists en ont une ; 2 sont blanches, 2 contiennent un saut de ligne.';
COMMENT ON COLUMN dim_playlist.collaborative IS
  'Source typee en CHAINE "true"/"false", convertie ici en boolean. 22 569 playlists a true.';
COMMENT ON COLUMN dim_playlist.modified_at IS
  'Source = epoch Unix. Verifie : 100% des valeurs sont des multiples de 86400 -> aucune information horaire, donc DATE et non timestamp. Etendue 2010-04-16 a 2017-11-01.';
COMMENT ON COLUMN dim_playlist.num_followers IS
  'PIEGE DE TYPAGE : max 71 643, donc integer obligatoire. Un smallint (32 767) deborderait.';
COMMENT ON COLUMN dim_playlist.num_tracks IS
  'Max 376 (playlist_id 864737), au-dela de la limite de 250 annoncee par la documentation du MPD.';
COMMENT ON COLUMN dim_playlist.name IS
  '70 011 noms comportent des espaces de bord et 28 222 des emoji hors BMP. Utiliser name_norm pour toute recherche.';


-- =====================================================================
--  FAIT  -  66 346 428 lignes
--  Grain : une ligne = une piste a une position donnee d'une playlist.
--  artist_sk est DENORMALISE (redondant avec dim_track) : +300 Mo de heap,
--  mais supprime une jointure sur 66 M lignes pour toute analyse par artiste.
-- =====================================================================
CREATE TABLE fact_playlist_track (
    playlist_id  integer  NOT NULL REFERENCES dim_playlist(playlist_id),
    track_sk     integer  NOT NULL REFERENCES dim_track(track_sk),
    artist_sk    integer  NOT NULL REFERENCES dim_artist(artist_sk),
    pos          smallint NOT NULL,             -- max 375
    CONSTRAINT pk_fact PRIMARY KEY (playlist_id, pos)
) WITH (fillfactor = 100);                      -- table en lecture seule
COMMENT ON TABLE fact_playlist_track IS
  'Table de faits sans mesure additive (factless fact table). Grain : (playlist, position). '
  'PK sur (playlist_id, pos) et NON (playlist_id, track_sk) : 881 652 pistes apparaissent plusieurs fois dans une meme playlist.';
COMMENT ON COLUMN fact_playlist_track.artist_sk IS
  'Denormalisation assumee depuis dim_track, pour eviter une jointure sur 66 M lignes dans les analyses par artiste.';


-- =====================================================================
--  STAGING  (UNLOGGED : ni WAL ni journalisation, detruit apres chargement)
-- =====================================================================
CREATE UNLOGGED TABLE staging.stg_item (
    playlist_id integer     NOT NULL,
    pos         smallint    NOT NULL,
    track_id    varchar(22) NOT NULL
);

CREATE UNLOGGED TABLE staging.stg_track (
    track_id    varchar(22) NOT NULL,
    track_name  text        NOT NULL,
    artist_id   varchar(22) NOT NULL,
    album_id    varchar(22) NOT NULL,
    duration_ms integer     NOT NULL
);

CREATE UNLOGGED TABLE staging.stg_artist (
    artist_id   varchar(22) NOT NULL,
    artist_name text        NOT NULL
);

CREATE UNLOGGED TABLE staging.stg_album (
    album_id    varchar(22) NOT NULL,
    album_name  text        NOT NULL
);

CREATE UNLOGGED TABLE staging.stg_playlist (
    playlist_id   integer  NOT NULL,
    name          text     NOT NULL,
    description   text,
    collaborative text     NOT NULL,   -- recu brut "true"/"false", caste en 03
    modified_at   bigint   NOT NULL,   -- recu brut en epoch, caste en 03
    num_tracks    integer  NOT NULL,
    num_albums    integer  NOT NULL,
    num_artists   integer  NOT NULL,
    num_edits     integer  NOT NULL,
    num_followers integer  NOT NULL,
    duration_ms   bigint   NOT NULL
);
