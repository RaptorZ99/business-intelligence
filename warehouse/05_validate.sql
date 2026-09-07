-- =====================================================================
--  ENTREPOT MPD  -  05. Recette
--  L'entrepot doit reproduire EXACTEMENT les valeurs obtenues par les
--  scans Python independants sur les 31 Go de JSON. Toute divergence
--  signale une perte ou une corruption au chargement.
-- =====================================================================
\pset format aligned
\echo '===================== RECETTE DE L''ENTREPOT ====================='

WITH t(id, libelle, attendu, obtenu) AS (
    -- Volumetrie
    SELECT 1,'dim_artist',                       295860, (SELECT count(*) FROM dim_artist)
    UNION ALL SELECT 2,'dim_album',              734684, (SELECT count(*) FROM dim_album)
    UNION ALL SELECT 3,'dim_track',             2262292, (SELECT count(*) FROM dim_track)
    UNION ALL SELECT 4,'dim_playlist',          1000000, (SELECT count(*) FROM dim_playlist)
    UNION ALL SELECT 5,'fact (lignes-pistes)', 66346428, (SELECT count(*) FROM fact_playlist_track)
    -- Qualite : anomalies qui DOIVENT avoir survecu au chargement
    UNION ALL SELECT 6,'playlists collaboratives',  22569,
        (SELECT count(*) FROM dim_playlist WHERE collaborative)
    UNION ALL SELECT 7,'descriptions presentes',    18760,
        (SELECT count(*) FROM dim_playlist WHERE description IS NOT NULL)
    UNION ALL SELECT 8,'pistes de duree -1',            1,
        (SELECT count(*) FROM dim_track WHERE duration_ms = -1)
    UNION ALL SELECT 9,'pistes de duree 0',          1086,
        (SELECT count(*) FROM fact_playlist_track f JOIN dim_track t USING (track_sk)
         WHERE t.duration_ms = 0)
    UNION ALL SELECT 10,'max num_tracks (piege 376)',  376,
        (SELECT max(num_tracks) FROM dim_playlist)
    UNION ALL SELECT 11,'max num_followers (>smallint)',71643,
        (SELECT max(num_followers) FROM dim_playlist)
    UNION ALL SELECT 12,'artiste nomme litteralement \N', 1,
        (SELECT count(*) FROM dim_artist WHERE artist_name = E'\\N')
    -- strpos et non LIKE : dans un motif LIKE, l'antislash est le caractere
    -- d'echappement, donc '%\%' cherche un signe pourcent litteral (65 lignes).
    UNION ALL SELECT 13,'noms d''artiste avec antislash', 15162,
        (SELECT count(*) FROM fact_playlist_track f JOIN dim_artist a USING (artist_sk)
         WHERE strpos(a.artist_name, chr(92)) > 0)
    UNION ALL SELECT 14,'doublons piste intra-playlist',881652,
        (SELECT COALESCE(sum(n-1),0) FROM (SELECT playlist_id, track_sk, count(*) n
         FROM fact_playlist_track GROUP BY 1,2 HAVING count(*) > 1) z)
    -- 38 235 et non 23 979 : le profilage Python detectait la multiplicite par
    -- worker et manquait les albums dont les artistes tombaient dans des
    -- partitions differentes. Le comptage SQL, global, fait foi.
    UNION ALL SELECT 15,'albums a plusieurs artistes',  38235,
        (SELECT count(*) FROM (SELECT album_sk FROM dim_track GROUP BY 1
                               HAVING count(DISTINCT artist_sk) > 1) z)
    -- Reproduction des analyses menees en Python
    UNION ALL SELECT 16,'Beyonce : occurrences',       230857,
        (SELECT count(*) FROM fact_playlist_track f JOIN dim_artist a USING (artist_sk)
         WHERE a.artist_id = '6vWDO969PvNqNYHIOW5v0m')
    UNION ALL SELECT 17,'Beyonce : pistes distinctes',    319,
        (SELECT count(DISTINCT f.track_sk) FROM fact_playlist_track f JOIN dim_artist a USING (artist_sk)
         WHERE a.artist_id = '6vWDO969PvNqNYHIOW5v0m')
    UNION ALL SELECT 18,'Beyonce : playlists',          97468,
        (SELECT count(DISTINCT f.playlist_id) FROM fact_playlist_track f JOIN dim_artist a USING (artist_sk)
         WHERE a.artist_id = '6vWDO969PvNqNYHIOW5v0m')
    -- PIEGE : 6 artistes distincts se nomment "Drake". On adresse l'identifiant,
    -- jamais le nom -- exactement la lecon tiree de l'analyse Beyonce.
    UNION ALL SELECT 19,'Drake (le vrai) : occ. globales', 846937,
        (SELECT s.n_occurrences FROM mv_artist_stats s
         WHERE s.artist_id = '3TVXtAsR1Inumwj472S9r4')
    UNION ALL SELECT 20,'noms d''artiste homonymes',        5991,
        (SELECT count(*) FROM (SELECT artist_name FROM dim_artist
                               GROUP BY 1 HAVING count(*) > 1) z)
)
SELECT id, libelle,
       to_char(attendu,'FM999,999,999') AS attendu,
       to_char(obtenu ,'FM999,999,999') AS obtenu,
       CASE WHEN attendu = obtenu THEN 'OK' ELSE '### ECART ###' END AS verdict
FROM t ORDER BY id;

\echo ''
\echo '--- Top 3 des artistes dans les playlists contenant Beyonce ---'
\echo '--- attendu : Drake 177 235 | Rihanna 165 745 | Kanye West 97 892 ---'
WITH pl AS (
    SELECT DISTINCT f.playlist_id
    FROM fact_playlist_track f JOIN dim_artist a USING (artist_sk)
    WHERE a.artist_id = '6vWDO969PvNqNYHIOW5v0m'
)
-- Regroupement sur artist_sk et NON sur le nom : 6 artistes se nomment "Drake",
-- grouper par nom les fusionnerait et gonflerait le total de 8 occurrences.
SELECT a.artist_name, a.artist_id,
       count(*)                      AS occurrences,
       count(DISTINCT f.playlist_id) AS playlists
FROM fact_playlist_track f
JOIN pl USING (playlist_id)
JOIN dim_artist a USING (artist_sk)
WHERE a.artist_id <> '6vWDO969PvNqNYHIOW5v0m'
GROUP BY a.artist_sk, a.artist_name, a.artist_id
ORDER BY occurrences DESC LIMIT 3;

\echo ''
\echo '--- Encombrement ---'
SELECT c.relname AS objet,
       pg_size_pretty(pg_relation_size(c.oid))       AS donnees,
       pg_size_pretty(pg_indexes_size(c.oid))        AS index,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r','m')
ORDER BY pg_total_relation_size(c.oid) DESC;
SELECT pg_size_pretty(pg_database_size('mpd')) AS "base mpd";
