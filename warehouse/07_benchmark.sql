-- =====================================================================
--  ENTREPOT MPD  -  07. Banc d'essai
--  Chaque requete est representative d'une famille d'usage.
-- =====================================================================
\timing on
\pset format aligned

\echo '=== 1. Occurrences d''un artiste (parcours index-only sur ix_fact_artist) ==='
SELECT count(*) FROM fact_playlist_track
WHERE artist_sk = (SELECT artist_sk FROM dim_artist WHERE artist_id = '6vWDO969PvNqNYHIOW5v0m');

\echo '=== 2. Top 10 artistes du dataset (agregat materialise) ==='
SELECT artist_name, n_occurrences FROM mv_artist_stats
ORDER BY n_occurrences DESC LIMIT 10;

\echo '=== 3. Recherche de sous-chaine sur 2,26 M titres (GIN trigramme) ==='
SELECT count(*) FROM dim_track WHERE track_name_norm LIKE '%' || norm('crazy in love') || '%';

\echo '=== 4. Recherche d''artiste sans accent (le piege Beyonce) ==='
SELECT artist_name FROM dim_artist
WHERE artist_name_norm LIKE norm('beyonce') || '%' ORDER BY artist_name LIMIT 5;

\echo '=== 5. Contenu ordonne d''une playlist (PK) ==='
SELECT count(*) FROM v_playlist_track WHERE playlist_id = 500000;

\echo '=== 6. Top 3 artistes dans les playlists contenant Beyonce (2 passes sur 66 M) ==='
WITH pl AS (
    SELECT DISTINCT playlist_id FROM fact_playlist_track
    WHERE artist_sk = (SELECT artist_sk FROM dim_artist WHERE artist_id='6vWDO969PvNqNYHIOW5v0m')
)
-- Regroupement sur artist_sk : 6 artistes distincts se nomment "Drake".
SELECT a.artist_name, count(*) AS occurrences
FROM fact_playlist_track f JOIN pl USING (playlist_id) JOIN dim_artist a USING (artist_sk)
GROUP BY a.artist_sk, a.artist_name ORDER BY 2 DESC LIMIT 4;

\echo '=== 7. Agregat sur toute la table de faits (66 M lignes, parallelise) ==='
SELECT count(DISTINCT playlist_id) AS playlists, count(DISTINCT track_sk) AS pistes
FROM fact_playlist_track;
