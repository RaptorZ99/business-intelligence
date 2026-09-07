# Business Intelligence & Analytics — M2 EFREI

Entrepôt de données PostgreSQL construit sur le **Spotify Million Playlist Dataset**
(31,2 Go de JSON, 1 000 slices).

## Contenu

| | |
|---|---|
| [`warehouse/`](warehouse/) | Le pipeline complet — schéma, chargement, transformation, index, recette |
| [`warehouse/README.md`](warehouse/README.md) | Documentation détaillée : modèle, pièges de la source, choix de performance |
| [`warehouse/mpd.dbml`](warehouse/mpd.dbml) | Diagramme du modèle, à ouvrir dans [dbdiagram.io](https://dbdiagram.io) |

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
