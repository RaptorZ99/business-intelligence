# Business Intelligence & Analytics — M2 EFREI

Le **Spotify Million Playlist Dataset** (31,2 Go de JSON, 1 000 slices) converti
en Parquet : deux tables, sans serveur, en **20 secondes**.

```
bronze/   31,2 Go   1 000 fichiers JSON bruts, non versionnés
   |
   |  build_silver.py        20,2 s
   v
silver/    2,6 Go   2 000 fichiers Parquet, deux tables
```

## Utilisation

```bash
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/python build_silver.py
```

Le dataset source n'est pas versionné. Placez les fichiers `mpd.slice.*.json`
dans `bronze/` à la racine, ou pointez `MPD_BRONZE` ailleurs.

| | |
|---|---:|
| Durée | **20,2 s** (1 580 Mo/s) |
| Entrée | 31,2 Go de JSON |
| Sortie | 2 627 Mo de Parquet — facteur **×12,2** |
| Lignes | 1 000 000 playlists · 66 346 428 pistes |

## Disposition

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
retraiter les 31 Go.

## Modèle

Deux tables, jointes sur `playlist_id`. La table `track` porte les attributs de
la piste : le modèle est autosuffisant, sans dimension séparée.

**`track`** — une ligne par piste dans une playlist

| Colonne | Type |
|---|---|
| `playlist_id` | `int32` |
| `pos` | `int16` |
| `track_id` `artist_id` `album_id` | `string` — base62 Spotify, 22 caractères |
| `track_name` `artist_name` `album_name` | `string` |
| `duration_ms` | `int32` |

**`playlist`** — une ligne par playlist

| Colonne | Type |
|---|---|
| `playlist_id` | `int32` |
| `name` | `string` |
| `description` | `string` — `null` quand le champ est absent |
| `collaborative` | `bool` |
| `modified_at` | `date32` |
| `num_tracks` `num_albums` `num_artists` `num_edits` | `int16` |
| `num_followers` | `int32` |
| `duration_ms` | `int64` |

## Lecture

Un glob se lit comme une seule table :

```sql
-- DuckDB
SELECT artist_name, count(*) AS n
FROM 'silver/track.*.parquet'
GROUP BY 1 ORDER BY n DESC LIMIT 10;
```

```python
import glob, pyarrow.dataset as ds
tr = ds.dataset(sorted(glob.glob("silver/track.*.parquet")))
tr.count_rows(filter=ds.field("artist_id") == "6vWDO969PvNqNYHIOW5v0m")   # 230 857
```

## Choix techniques

- **`orjson`** au lieu du module `json` : mesuré 16 % plus rapide sur
  l'ensemble du traitement (26,3 s → 22,0 s à nombre de workers égal).
- **zstd niveau 1** : mesuré 26 % plus compact que snappy pour une durée
  identique.
- **Une slice par tâche**, réparties dynamiquement sur `os.cpu_count()`
  workers : meilleur équilibrage que des blocs fixes, mémoire bornée.
- **Aucune erreur avalée** : une slice illisible fait échouer le script avec un
  code de sortie non nul, plutôt que de produire un jeu incomplet en annonçant
  un succès.
- **Typage explicite**, aucune inférence.

## Le typage vient de mesures, pas d'hypothèses

Les 66 346 428 lignes sources ont été profilées avant d'écrire le moindre
schéma. Ce que ça a changé :

| Constat sur la source | Conséquence |
|---|---|
| `num_followers` monte à **71 643** | `int32` — un `int16` (32 767) déborderait |
| `modified_at` est un epoch **toujours aligné minuit UTC** | `date32`, pas un timestamp : aucune information horaire à la source |
| `collaborative` est une **chaîne** `"true"` / `"false"` | converti en `bool` |
| `description` **absente** (981 240) ≠ description vide | `null` pour l'absence, valeur brute sinon |
| Une piste a `duration_ms = **-1**` | valeur conservée, pas de contrainte de positivité |
| `num_tracks` monte à **376** | au-delà de la limite de 250 annoncée par la doc du MPD |

## Pièges à connaître pour interroger ces données

| | |
|---|---|
| **5 991 noms d'artiste sont des homonymes** — six artistes distincts s'appellent « Drake » | agréger sur `artist_id`, **jamais** sur le nom |
| **881 652 pistes apparaissent plusieurs fois dans une même playlist** | `(playlist_id, track_id)` n'est pas unique ; la clé est `(playlist_id, pos)` |
| **38 235 albums portent des pistes de plusieurs artistes** (compilations) | un album n'appartient pas à un artiste |
| **1 086 pistes durent 0 ms**, une vaut −1 | filtrer `duration_ms > 0` pour tout calcul de durée |
| **28 618 noms contiennent des emoji hors BMP**, ~4 800 des contrôles C1 (mojibake Windows-1252) | désaccentuer et normaliser avant toute recherche par nom |
| Un artiste se nomme **littéralement `\N`** | ne jamais utiliser de sentinelle textuelle dans un export |
