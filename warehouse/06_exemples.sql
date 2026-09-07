-- =====================================================================
--  ENTREPOT MPD  -  06. Requetes types
--  Chacune illustre un usage ET, le cas echeant, le piege a eviter.
-- =====================================================================


-- 1. RECHERCHE D'ARTISTE, insensible a la casse ET aux accents.
--    C'est LE piege du dataset : "Beyonce" sans accent ne matche jamais
--    "Beyonce" accentue. La colonne _norm et la fonction norm() le reglent.
SELECT a.artist_id, a.artist_name, s.n_occurrences, s.n_playlists, s.n_tracks
FROM dim_artist a JOIN mv_artist_stats s USING (artist_sk)
WHERE a.artist_name_norm LIKE '%' || norm('beyonce') || '%'
ORDER BY s.n_occurrences DESC;

-- 2. Occurrences d'un artiste (index-only sur ix_fact_artist).
SELECT count(*) AS occurrences
FROM fact_playlist_track f
WHERE f.artist_sk = (SELECT artist_sk FROM dim_artist WHERE artist_id = '6vWDO969PvNqNYHIOW5v0m');

-- 3. Top artistes du dataset : instantane grace a l'agregat materialise.
SELECT artist_name, n_occurrences, n_playlists
FROM mv_artist_stats ORDER BY n_occurrences DESC LIMIT 10;

-- 4. Le catalogue d'un artiste, trie par popularite.
SELECT t.track_name, al.album_name, ts.n_occurrences
FROM mv_track_stats ts
JOIN dim_track t  USING (track_sk)
JOIN dim_album al USING (album_sk)
WHERE t.artist_sk = (SELECT artist_sk FROM dim_artist WHERE artist_id = '6vWDO969PvNqNYHIOW5v0m')
ORDER BY ts.n_occurrences DESC LIMIT 20;

-- 5. AFFINITE entre artistes : qui accompagne X plus souvent que le hasard ?
--    La sur-representation neutralise l'effet de taille (un artiste enorme
--    sort premier partout sans rien dire de son affinite reelle).
WITH cible AS (SELECT artist_sk FROM dim_artist WHERE artist_id = '6vWDO969PvNqNYHIOW5v0m'),
     pl    AS (SELECT DISTINCT playlist_id FROM fact_playlist_track
               WHERE artist_sk = (SELECT artist_sk FROM cible)),
     local AS (SELECT f.artist_sk, count(DISTINCT f.playlist_id) AS n_pl
               FROM fact_playlist_track f JOIN pl USING (playlist_id)
               GROUP BY 1)
SELECT a.artist_name,
       l.n_pl                                        AS playlists_avec_cible,
       s.n_playlists                                 AS playlists_global,
       round(100.0 * l.n_pl / (SELECT count(*) FROM pl), 1)      AS pct_local,
       round(100.0 * s.n_playlists / 1000000, 1)                 AS pct_global,
       round((l.n_pl::numeric / (SELECT count(*) FROM pl))
           / (s.n_playlists::numeric / 1000000), 1)              AS sur_representation
FROM local l
JOIN dim_artist a      USING (artist_sk)
JOIN mv_artist_stats s USING (artist_sk)
WHERE l.n_pl >= 2000 AND a.artist_sk <> (SELECT artist_sk FROM cible)
ORDER BY sur_representation DESC LIMIT 15;

-- 6. Recherche plein texte par sous-chaine sur 2,26 M de titres (index GIN trigramme).
SELECT t.track_name, a.artist_name, ts.n_occurrences
FROM dim_track t JOIN dim_artist a USING (artist_sk) JOIN mv_track_stats ts USING (track_sk)
WHERE t.track_name_norm LIKE '%' || norm('crazy in love') || '%'
ORDER BY ts.n_occurrences DESC LIMIT 10;

-- 7. Les playlists les plus suivies.
SELECT playlist_id, name, num_tracks, num_followers, modified_at
FROM dim_playlist ORDER BY num_followers DESC LIMIT 10;

-- 8. Contenu ordonne d'une playlist (parcours d'index sur la PK).
SELECT pos, artist_name, track_name, album_name
FROM v_playlist_track WHERE playlist_id = 0 ORDER BY pos;

-- 9. Duree moyenne d'une piste.
--    PIEGE : filtrer duration_ms > 0, sinon la piste a -1 ms et les 1 086
--    lignes a 0 ms polluent la moyenne.
SELECT round(avg(duration_ms) / 1000.0, 1) AS duree_moyenne_s
FROM dim_track WHERE duration_ms > 0;

-- 10. Compilations : albums portant des pistes de plusieurs artistes.
SELECT al.album_name, count(DISTINCT t.artist_sk) AS nb_artistes, count(*) AS nb_pistes
FROM dim_track t JOIN dim_album al USING (album_sk)
GROUP BY 1 HAVING count(DISTINCT t.artist_sk) > 1
ORDER BY nb_artistes DESC LIMIT 10;

-- 11. Activite dans le temps (modified_at est une DATE, pas un timestamp).
SELECT date_trunc('year', modified_at)::date AS annee,
       count(*) AS playlists, sum(num_tracks) AS pistes
FROM dim_playlist GROUP BY 1 ORDER BY 1;

-- 12. Playlists collaboratives (index partiel : 2,3 % des lignes).
SELECT count(*) FROM dim_playlist WHERE collaborative;
