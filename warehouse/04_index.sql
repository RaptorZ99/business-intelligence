-- =====================================================================
--  ENTREPOT MPD  -  04. Contraintes, index, agregats
-- =====================================================================
\timing on
SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 4;
SET work_mem = '1GB';
SET synchronous_commit = off;

-- --- Integrite (rebatie apres chargement, bien plus rapide) ------------
ALTER TABLE fact_playlist_track ADD CONSTRAINT pk_fact PRIMARY KEY (playlist_id, pos);
ALTER TABLE fact_playlist_track ADD CONSTRAINT fk_fact_playlist
      FOREIGN KEY (playlist_id) REFERENCES dim_playlist(playlist_id);
ALTER TABLE fact_playlist_track ADD CONSTRAINT fk_fact_track
      FOREIGN KEY (track_sk) REFERENCES dim_track(track_sk);
ALTER TABLE fact_playlist_track ADD CONSTRAINT fk_fact_artist
      FOREIGN KEY (artist_sk) REFERENCES dim_artist(artist_sk);

-- --- Acces analytiques sur la table de faits --------------------------
-- (colonne, playlist_id) : permet un parcours index-only, sans toucher au heap.
CREATE INDEX ix_fact_artist ON fact_playlist_track (artist_sk, playlist_id);
CREATE INDEX ix_fact_track  ON fact_playlist_track (track_sk,  playlist_id);

-- --- Cles etrangeres des dimensions -----------------------------------
CREATE INDEX ix_track_artist ON dim_track (artist_sk);
CREATE INDEX ix_track_album  ON dim_track (album_sk);

-- --- Recherche textuelle ----------------------------------------------
-- GIN trigramme : ILIKE '%motif%' sans parcours complet. Les colonnes _norm
-- sont desaccentuees et en minuscules -> "beyonce" retrouve "Beyonce" accentue,
-- ce qui est exactement le piege rencontre lors de l'analyse.
CREATE INDEX ix_artist_trgm ON dim_artist   USING gin (artist_name_norm gin_trgm_ops);
CREATE INDEX ix_track_trgm  ON dim_track    USING gin (track_name_norm  gin_trgm_ops);
CREATE INDEX ix_album_trgm  ON dim_album    USING gin (album_name_norm  gin_trgm_ops);
CREATE INDEX ix_pl_trgm     ON dim_playlist USING gin (name_norm        gin_trgm_ops);
-- btree complementaire : egalite et prefixe, bien plus rapides qu'un GIN.
CREATE INDEX ix_artist_norm ON dim_artist   (artist_name_norm);
CREATE INDEX ix_track_norm  ON dim_track    (track_name_norm);
CREATE INDEX ix_pl_norm     ON dim_playlist (name_norm);

-- --- Axes d'analyse de la playlist ------------------------------------
CREATE INDEX ix_pl_modified  ON dim_playlist (modified_at);
CREATE INDEX ix_pl_followers ON dim_playlist (num_followers DESC);
CREATE INDEX ix_pl_collab    ON dim_playlist (playlist_id) WHERE collaborative;  -- 2,3 % des lignes

-- =====================================================================
--  Vue a plat : confort d'exploration ad hoc
-- =====================================================================
CREATE OR REPLACE VIEW v_playlist_track AS
SELECT f.playlist_id, p.name AS playlist_name, f.pos,
       t.track_id, t.track_name, t.duration_ms,
       ar.artist_id, ar.artist_name,
       al.album_id, al.album_name
FROM fact_playlist_track f
JOIN dim_playlist p ON p.playlist_id = f.playlist_id
JOIN dim_track    t ON t.track_sk    = f.track_sk
JOIN dim_artist  ar ON ar.artist_sk  = f.artist_sk
JOIN dim_album   al ON al.album_sk   = t.album_sk;
COMMENT ON VIEW v_playlist_track IS 'Vue denormalisee des 66 346 428 lignes-pistes. Pratique en ad hoc, a eviter dans les agregats lourds (preferer la table de faits).';

-- =====================================================================
--  Agregats materialises : rendent instantanees les questions courantes
-- =====================================================================
CREATE MATERIALIZED VIEW mv_artist_stats AS
SELECT a.artist_sk, a.artist_id, a.artist_name,
       COALESCE(o.n_occurrences, 0) AS n_occurrences,   -- lignes-pistes
       COALESCE(o.n_playlists,   0) AS n_playlists,     -- playlists distinctes
       COALESCE(c.n_tracks,      0) AS n_tracks         -- pistes au catalogue
FROM dim_artist a
LEFT JOIN (
    SELECT artist_sk, sum(n)::bigint AS n_occurrences, count(*)::bigint AS n_playlists
    FROM (SELECT artist_sk, playlist_id, count(*) AS n
          FROM fact_playlist_track GROUP BY 1, 2) z
    GROUP BY 1
) o ON o.artist_sk = a.artist_sk
LEFT JOIN (
    SELECT artist_sk, count(*)::bigint AS n_tracks FROM dim_track GROUP BY 1
) c ON c.artist_sk = a.artist_sk;
CREATE UNIQUE INDEX ix_mvartist_sk  ON mv_artist_stats (artist_sk);
CREATE INDEX        ix_mvartist_occ ON mv_artist_stats (n_occurrences DESC);
CREATE INDEX        ix_mvartist_pl  ON mv_artist_stats (n_playlists   DESC);
COMMENT ON MATERIALIZED VIEW mv_artist_stats IS 'Popularite par artiste. REFRESH MATERIALIZED VIEW apres tout rechargement.';

CREATE MATERIALIZED VIEW mv_track_stats AS
SELECT t.track_sk, t.track_id, t.track_name, t.artist_sk,
       COALESCE(o.n_occurrences, 0) AS n_occurrences,
       COALESCE(o.n_playlists,   0) AS n_playlists
FROM dim_track t
LEFT JOIN (
    SELECT track_sk, sum(n)::bigint AS n_occurrences, count(*)::bigint AS n_playlists
    FROM (SELECT track_sk, playlist_id, count(*) AS n
          FROM fact_playlist_track GROUP BY 1, 2) z
    GROUP BY 1
) o ON o.track_sk = t.track_sk;
CREATE UNIQUE INDEX ix_mvtrack_sk  ON mv_track_stats (track_sk);
CREATE INDEX        ix_mvtrack_occ ON mv_track_stats (n_occurrences DESC);

-- --- Statistiques du planificateur ------------------------------------
-- Echantillonnage renforce sur les colonnes de jointure de la table de faits.
ALTER TABLE fact_playlist_track ALTER COLUMN artist_sk   SET STATISTICS 1000;
ALTER TABLE fact_playlist_track ALTER COLUMN track_sk    SET STATISTICS 1000;
ALTER TABLE fact_playlist_track ALTER COLUMN playlist_id SET STATISTICS 1000;
VACUUM ANALYZE fact_playlist_track;
VACUUM ANALYZE dim_track;
VACUUM ANALYZE dim_artist;
VACUUM ANALYZE dim_album;
VACUUM ANALYZE dim_playlist;
ANALYZE mv_artist_stats;
ANALYZE mv_track_stats;
