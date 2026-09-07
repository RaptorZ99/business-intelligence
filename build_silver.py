#!/usr/bin/env python3
"""
Couche silver : bronze/ (31 Go de JSON brut) -> silver/ (Parquet).

Un dossier plat, une paire de fichiers par slice source :

    silver/playlist.0-999.parquet        1 000 lignes  - une ligne par playlist
    silver/track.0-999.parquet          ~66 000 lignes - une ligne par piste
    silver/playlist.1000-1999.parquet
    silver/track.1000-1999.parquet
    ...                                  (1 000 slices -> 2 000 fichiers)

Les deux tables se joignent sur playlist_id. La table track porte les attributs
de la piste : le modele est autosuffisant a deux tables.

Le decoupage 1:1 avec la source permet de rejouer une slice isolee sans
retraiter les 31 Go. Un glob se lit comme une seule table :

    SELECT * FROM 'silver/track.*.parquet'          -- DuckDB
    ds.dataset(glob.glob('silver/track.*.parquet')) -- pyarrow

Usage :  python3 build_silver.py [nb_slices_max]
         MPD_BRONZE=/chemin/vers/bronze python3 build_silver.py
"""
import os
import shutil
import sys
import time
from multiprocessing import Pool

import orjson
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("MPD_BRONZE") or os.path.join(HERE, "bronze")
OUT = os.path.join(HERE, "silver")
NWORKERS = os.cpu_count() or 8   # mesure : 12 workers > 11 > 8 sur cette machine
# zstd niveau 1 : mesure 26 % plus compact que snappy pour une duree identique.
CODEC = dict(compression="zstd", compression_level=1)

# Schemas explicites : aucune inference de type. Les entiers sont dimensionnes
# d'apres le profilage reel des 66 346 428 lignes sources.
PLAYLIST = pa.schema([
    ("playlist_id",   pa.int32()),
    ("name",          pa.string()),
    ("description",   pa.string()),   # null quand le champ est absent du JSON
    ("collaborative", pa.bool_()),    # source : chaine "true"/"false"
    ("modified_at",   pa.date32()),   # epoch toujours aligne minuit UTC -> une date
    ("num_tracks",    pa.int16()),    # max 376
    ("num_albums",    pa.int16()),    # max 244
    ("num_artists",   pa.int16()),    # max 238
    ("num_edits",     pa.int16()),    # max 201
    ("num_followers", pa.int32()),    # max 71 643 : int16 deborderait
    ("duration_ms",   pa.int64()),    # max 635 073 792
])

TRACK = pa.schema([
    ("playlist_id", pa.int32()),
    ("pos",         pa.int16()),
    ("track_id",    pa.string()),
    ("track_name",  pa.string()),
    ("artist_id",   pa.string()),
    ("artist_name", pa.string()),
    ("album_id",    pa.string()),
    ("album_name",  pa.string()),
    ("duration_ms", pa.int32()),      # vaut -1 sur une piste de la source
])


def write(path, schema, cols):
    pq.write_table(
        pa.Table.from_arrays(
            [pa.array(c, type=f.type) for c, f in zip(cols, schema)], schema=schema),
        path, **CODEC)
    return len(cols[0])


def build(path):
    """Convertit une slice JSON en sa paire de fichiers Parquet."""
    sid = os.path.basename(path)[len("mpd.slice."):-len(".json")]   # "0-999"
    P = [[] for _ in PLAYLIST]
    T = [[] for _ in TRACK]

    for pl in orjson.loads(open(path, "rb").read())["playlists"]:
        pid = pl["pid"]
        P[0].append(pid)
        P[1].append(pl["name"])
        P[2].append(pl.get("description"))
        P[3].append(pl["collaborative"] == "true")
        P[4].append(pl["modified_at"] // 86400)          # date32 = jours depuis l'epoch
        P[5].append(pl["num_tracks"])
        P[6].append(pl["num_albums"])
        P[7].append(pl["num_artists"])
        P[8].append(pl["num_edits"])
        P[9].append(pl["num_followers"])
        P[10].append(pl["duration_ms"])
        for t in pl["tracks"]:
            T[0].append(pid)
            T[1].append(t["pos"])
            T[2].append(t["track_uri"][14:])             # retire "spotify:track:"
            T[3].append(t["track_name"])
            T[4].append(t["artist_uri"][15:])
            T[5].append(t["artist_name"])
            T[6].append(t["album_uri"][14:])
            T[7].append(t["album_name"])
            T[8].append(t["duration_ms"])

    return (write(f"{OUT}/playlist.{sid}.parquet", PLAYLIST, P),
            write(f"{OUT}/track.{sid}.parquet", TRACK, T))


def main():
    files = sorted(os.path.join(SRC, f) for f in os.listdir(SRC)
                   if f.startswith("mpd.slice.") and f.endswith(".json"))
    if len(sys.argv) > 1:
        files = files[:int(sys.argv[1])]

    shutil.rmtree(OUT, ignore_errors=True)               # reconstruction propre
    os.makedirs(OUT)

    t0 = time.perf_counter()
    n_pl = n_tr = 0
    with Pool(NWORKERS) as pool:
        for a, b in pool.imap_unordered(build, files, chunksize=4):
            n_pl += a
            n_tr += b
    wall = time.perf_counter() - t0

    src_go = sum(os.path.getsize(f) for f in files) / 2**30
    out_mo = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT)) / 2**20
    print(f"  {len(files):,} slices -> {len(os.listdir(OUT)):,} fichiers Parquet")
    print(f"  playlist : {n_pl:>12,} lignes")
    print(f"  track    : {n_tr:>12,} lignes")
    print(f"  {src_go:.1f} Go JSON -> {out_mo:,.0f} Mo Parquet (x{src_go * 1024 / out_mo:.1f})")
    print(f"  {wall:.1f} s  ({src_go * 1024 / wall:.0f} Mo/s)")


if __name__ == "__main__":
    main()
