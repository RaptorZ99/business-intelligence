# Entrepôt MPD — Spotify Million Playlist Dataset sur PostgreSQL 16

Modèle en étoile construit à partir de 31 Go de JSON (1 000 slices), après
profilage exhaustif des **66 346 428 lignes-pistes** sources.

## Démarrage

```bash
createdb -E UTF8 -T template0 --locale=en_US.UTF-8 mpd
psql -v ON_ERROR_STOP=1 -d mpd -f 01_schema.sql
python3 02_load.py                 # 31 Go -> staging, sans fichier intermédiaire
psql -v ON_ERROR_STOP=1 -d mpd -f 03_transform.sql
psql -v ON_ERROR_STOP=1 -d mpd -f 04_index.sql
psql -d mpd -f 05_validate.sql     # recette : doit afficher OK partout
```

## Modèle

```
                  dim_artist (295 860)
                       ^        ^
                       |        |
   dim_album ----- dim_track    |        dim_playlist (1 000 000)
    (734 684)      (2 262 292)  |              ^
                       ^        |              |
                       |        |              |
              fact_playlist_track (66 346 428)
              (playlist_id, pos) = clé primaire
```

Grain du fait : **une ligne = une piste à une position donnée d'une playlist**.
Table de faits *sans mesure* (« factless fact table ») : le fait à mesurer est
l'appartenance elle-même.

## Les pièges de la source, et comment ils sont traités

| # | Piège découvert au profilage | Traitement |
|---|---|---|
| 1 | **Un artiste se nomme littéralement `\N`** | Aucune sentinelle textuelle. `FORCE_NOT_NULL` sur toutes les colonnes texte, et un booléen `has_description` porte l'absence |
| 2 | **16 698 valeurs contiennent un antislash** (`Axwell /\ Ingrosso`) | `COPY FORMAT csv` obligatoire — en `FORMAT text` l'antislash est le caractère d'échappement et corrompt silencieusement |
| 3 | 2 descriptions contiennent un **saut de ligne** | Le CSV les cite correctement |
| 4 | **`num_followers` monte à 71 643** | `integer` — un `smallint` (32 767) déborderait |
| 5 | **`duration_ms = -1`** sur une piste | Valeur conservée, `CHECK (>= -1)`, anomalie documentée en `COMMENT` |
| 6 | `collaborative` est une **chaîne** `"true"`/`"false"` | Converti en `boolean` |
| 7 | `modified_at` : epoch **toujours aligné minuit UTC** | Typé `date`, pas `timestamp` : aucune information horaire à la source |
| 8 | **38 235 albums portent plusieurs artistes** (5,2 %) | `dim_album` **sans** clé artiste — une FK artiste fausserait ces albums |
| 9 | **881 652 pistes dupliquées** dans une même playlist | PK sur `(playlist_id, pos)`, jamais `(playlist_id, track_sk)` |
| 10 | **28 618 emoji hors BMP** (4 octets UTF-8) | Base créée en UTF8 strict |
| 11 | ~4 800 caractères de contrôle C1 (mojibake Windows-1252) | Conservés tels quels ; `norm()` neutralise l'essentiel pour la recherche |
| 12 | 70 011 noms de playlist avec **espaces de bord** | Colonnes `*_norm` générées : `btrim` + minuscules + sans accents |
| 13 | `num_tracks` monte à **376** (limite MPD annoncée : 250) | Aucune contrainte trop stricte |
| 14 | `description` **absente** ≠ description vide | `NULL` pour absente (981 240), valeur brute sinon |
| 15 | **5 991 noms d'artiste sont des homonymes** — 6 artistes distincts s'appellent « Drake » | Toujours agréger sur `artist_sk` / `artist_id`, **jamais** sur le nom |
| 16 | Côté requête : dans un motif `LIKE`, l'antislash est le caractère d'échappement | Utiliser `strpos(col, chr(92)) > 0` pour chercher un antislash |

## Choix de performance

- **Clés de substitution `integer`** plutôt que les identifiants base62 de 22 caractères :
  la table de faits passe d'environ 5,3 Go à 2,7 Go, et les index de moitié.
- **`artist_sk` dénormalisé** dans le fait : +300 Mo, mais supprime une jointure
  sur 66 M lignes pour toute analyse par artiste.
- **Faits écrits physiquement triés** par `playlist_id` (`ORDER BY` au chargement) :
  localité maximale pour les requêtes centrées playlist.
- **Index GIN trigramme** sur les colonnes `_norm` : `LIKE '%motif%'` sans parcours complet.
- **Agrégats matérialisés** `mv_artist_stats` / `mv_track_stats` : les questions
  de popularité deviennent instantanées au lieu de balayer 66 M lignes.
- Contraintes et index **créés après** chargement (bien plus rapide qu'un maintien ligne à ligne).
- Réglages portés par `ALTER DATABASE mpd` : **le serveur PostgreSQL partagé n'est pas modifié**.

## Recette

`05_validate.sql` compare l'entrepôt aux valeurs obtenues par des scans Python
indépendants sur les 31 Go — volumétrie, anomalies, et reproduction des analyses
Beyoncé. Toute divergence signale une perte au chargement.

## Maintenance

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_artist_stats;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_track_stats;
DROP SCHEMA staging CASCADE;   -- libère ~5 Go une fois la recette passée
```
