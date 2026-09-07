-- =====================================================================
--  ENTREPOT MPD  -  03. Staging -> modele en etoile
--  Les cles de substitution sont attribuees par row_number() sur la cle
--  naturelle triee : dense, deterministe, donc reproductible a l'identique
--  d'un rechargement a l'autre.
-- =====================================================================
\timing on

SET maintenance_work_mem = '2GB';
SET work_mem             = '1GB';
SET max_parallel_workers_per_gather = 4;
SET max_parallel_maintenance_workers = 4;
SET synchronous_commit   = off;

-- Les contraintes de la table de faits sont retirees le temps du chargement
-- (maintenir un index sur 66 M insertions coute bien plus cher que le rebatir).
ALTER TABLE fact_playlist_track DROP CONSTRAINT IF EXISTS pk_fact;
ALTER TABLE fact_playlist_track DROP CONSTRAINT IF EXISTS fact_playlist_track_playlist_id_fkey;
ALTER TABLE fact_playlist_track DROP CONSTRAINT IF EXISTS fact_playlist_track_track_sk_fkey;
ALTER TABLE fact_playlist_track DROP CONSTRAINT IF EXISTS fact_playlist_track_artist_sk_fkey;

TRUNCATE fact_playlist_track, dim_track, dim_album, dim_artist, dim_playlist;

-- --- dim_artist -------------------------------------------------------
-- Le couple (artist_id, artist_name) est fonctionnellement determine
-- (0 divergence mesuree) : un simple DISTINCT suffit, sans arbitrage.
INSERT INTO dim_artist (artist_sk, artist_id, artist_name)
SELECT row_number() OVER (ORDER BY artist_id), artist_id, artist_name
FROM (SELECT DISTINCT artist_id, artist_name FROM staging.stg_track) s;

-- --- dim_album --------------------------------------------------------
INSERT INTO dim_album (album_sk, album_id, album_name)
SELECT row_number() OVER (ORDER BY album_id), album_id, album_name
FROM (SELECT DISTINCT album_id, album_name FROM staging.stg_track) s;

-- --- dim_track --------------------------------------------------------
-- stg_track contient des doublons (chaque worker a dedoublonne localement).
-- DISTINCT ON est sans risque ici : track_id determine strictement ses
-- attributs, toutes les copies sont donc identiques.
INSERT INTO dim_track (track_sk, track_id, track_name, artist_sk, album_sk, duration_ms)
SELECT row_number() OVER (ORDER BY t.track_id),
       t.track_id, t.track_name, ar.artist_sk, al.album_sk, t.duration_ms
FROM (SELECT DISTINCT ON (track_id) track_id, track_name, artist_id, album_id, duration_ms
      FROM staging.stg_track ORDER BY track_id) t
JOIN dim_artist ar ON ar.artist_id = t.artist_id
JOIN dim_album  al ON al.album_id  = t.album_id;

-- --- dim_playlist -----------------------------------------------------
INSERT INTO dim_playlist (playlist_id, name, description, collaborative, modified_at,
                          num_tracks, num_albums, num_artists, num_edits,
                          num_followers, duration_ms)
SELECT playlist_id,
       name,
       CASE WHEN has_description THEN description END,     -- absence portee par le booleen
       collaborative = 'true',                             -- chaine source -> boolean
       (to_timestamp(modified_at) AT TIME ZONE 'UTC')::date,-- epoch UTC -> date (aucune heure a la source)
       num_tracks, num_albums, num_artists, num_edits, num_followers, duration_ms
FROM staging.stg_playlist;

-- --- fact_playlist_track ---------------------------------------------
-- ORDER BY : la table est ecrite physiquement triee par playlist_id, ce qui
-- donne une correlation parfaite pour l'index BRIN et une excellente localite
-- pour toute requete centree playlist.
INSERT INTO fact_playlist_track (playlist_id, track_sk, artist_sk, pos)
SELECT i.playlist_id, t.track_sk, t.artist_sk, i.pos
FROM staging.stg_item i
JOIN dim_track t ON t.track_id = i.track_id
ORDER BY i.playlist_id, i.pos;

\echo '--- volumetrie obtenue ---'
SELECT 'dim_artist'   AS table, count(*) FROM dim_artist
UNION ALL SELECT 'dim_album',   count(*) FROM dim_album
UNION ALL SELECT 'dim_track',   count(*) FROM dim_track
UNION ALL SELECT 'dim_playlist',count(*) FROM dim_playlist
UNION ALL SELECT 'fact',        count(*) FROM fact_playlist_track;
