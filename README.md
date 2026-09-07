# Business Intelligence & Analytics — M2 EFREI

Entrepôt de données PostgreSQL construit sur le **Spotify Million Playlist Dataset**
(31,2 Go de JSON, 1 000 slices).

## Contenu

| | |
|---|---|
| [`warehouse/`](warehouse/) | Le pipeline complet — schéma, chargement, transformation, index, recette |
| [`warehouse/README.md`](warehouse/README.md) | Documentation détaillée : modèle, pièges de la source, choix de performance |
| [`warehouse/mpd.dbml`](warehouse/mpd.dbml) | Diagramme du modèle, à ouvrir dans [dbdiagram.io](https://dbdiagram.io) |
| [`build_silver.py`](build_silver.py) | Export Parquet en 33 s — deux tables, sans serveur |

## Volumétrie

| Table | Lignes | Taille |
|---|---:|---:|
| `fact_playlist_track` | 66 346 428 | 6,7 Go |
| `dim_track` | 2 262 292 | 606 Mo |
| `dim_album` | 734 684 | 156 Mo |
| `dim_artist` | 295 860 | 66 Mo |
| `dim_playlist` | 1 000 000 | 168 Mo |

## Construction

Le dataset source n'est pas versionné (31 Go). Placez les fichiers
`mpd.slice.*.json` dans un dossier `data/` à la racine, puis :

```bash
createdb -E UTF8 -T template0 --locale=en_US.UTF-8 mpd
psql -v ON_ERROR_STOP=1 -d mpd -f warehouse/01_schema.sql
python3 warehouse/02_load.py                                  #  34 s
psql -v ON_ERROR_STOP=1 -d mpd -f warehouse/03_transform.sql  # 3 min 51
psql -v ON_ERROR_STOP=1 -d mpd -f warehouse/04_index.sql      # 3 min 36
psql -d mpd -f warehouse/05_validate.sql                      # recette : 20/20
```

Environ **8 minutes** de bout en bout (12 cœurs, 16 Go de RAM, PostgreSQL 16).

## Performances

| Requête | Entrepôt |
|---|---:|
| Occurrences d'un artiste sur 66 M lignes | 19 ms |
| Top 10 artistes | 1,5 ms |
| Recherche de sous-chaîne sur 2,26 M titres | 34 ms |
| Recherche d'artiste insensible aux accents | 2 ms |
| Top 3 des co-artistes (2 passes sur 66 M) | 2,7 s |

---

## Couche silver — Parquet, sans serveur

Deux tables Parquet générées directement depuis le JSON, pour travailler sans
base de données.

```bash
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/python build_silver.py
```

**28 secondes** : 31,2 Go de JSON → 2,6 Go de Parquet (facteur 12,2), soit
1 141 Mo/s.

### Disposition

Un dossier plat, une paire de fichiers par slice source :

```
silver/
  playlist.0-999.parquet          1 000 lignes
  track.0-999.parquet            ~66 000 lignes
  playlist.1000-1999.parquet
  track.1000-1999.parquet
  ...                             1 000 slices -> 2 000 fichiers
                                  track 2 601 Mo | playlist 26 Mo
```

Le découpage 1:1 avec la source permet de rejouer une slice isolée sans
retraiter les 31 Go. Les deux tables se joignent sur `playlist_id` ; `track`
porte les attributs de la piste, le modèle est donc autosuffisant à deux tables.

### Lecture

Un glob se lit comme une seule table :

```sql
-- DuckDB
SELECT artist_name, count(*) FROM 'silver/track.*.parquet'
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

```python
import glob, pyarrow.dataset as ds
tr = ds.dataset(sorted(glob.glob("silver/track.*.parquet")))
tr.count_rows(filter=ds.field("artist_id") == "6vWDO969PvNqNYHIOW5v0m")   # 230 857
```

### Choix techniques

- **zstd niveau 1** — mesuré 26 % plus compact que snappy pour une durée
  identique. Le codec est vérifiable dans les métadonnées Parquet.
- **Typage explicite**, aucune inférence, dimensionné d'après le profilage de
  la source : `num_followers` en `int32` (max 71 643), `modified_at` en
  `date32` (l'epoch source est toujours aligné minuit UTC, converti par une
  simple division entière), `collaborative` en booléen.
- **Une slice par tâche**, réparties dynamiquement sur 8 workers : meilleur
  équilibrage que des blocs fixes, et mémoire naturellement bornée.

Compromis assumé de la disposition par fichier : un scan filtré sur les 66 M
de lignes prend 425 ms, contre 176 ms si tout était regroupé en 8 fichiers —
1 000 ouvertures de fichiers et lectures de pied de page au lieu de 8. En
échange, la construction est plus rapide, les fichiers plus compacts, et une
slice se rejoue seule.
