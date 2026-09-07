#!/usr/bin/env python3
"""
Couche silver : le Million Playlist Dataset (31 Go de JSON) en deux tables Parquet.

    silver/playlist/    1 000 000 lignes  - une ligne par playlist
    silver/track/      66 346 428 lignes  - une ligne par piste DANS une playlist

Les deux se joignent sur playlist_id. La table track porte les attributs de la
piste : le modele est autosuffisant a deux tables, sans dimension separee.

Parallelisme : chaque worker ecrit SON fichier. Aucune coordination, aucune
fusion. Un dossier de fichiers Parquet se lit comme une seule table, que ce
soit avec DuckDB, pandas, Polars ou Spark.

Usage :  python3 build_silver.py [nb_slices_max]
         MPD_DATA=/chemin/vers/data python3 build_silver.py
"""
import json
import os
import shutil
import sys
import time
from multiprocessing import Pool

import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("MPD_DATA") or os.path.join(HERE, "data")
OUT = os.path.join(HERE, "silver")
NWORKERS = 8
ROWS_PER_GROUP = 512 * 1024      # taille de row group : compromis memoire / lecture

# Schemas explicites : aucune inference de type, aucune surprise.
# Les entiers sont dimensionnes d'apres le profilage reel de la source.
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


def flush(writer, schema, cols):
    """Ecrit un row group et vide les tampons."""
    n = len(cols[0])
    if n:
        writer.write_table(pa.Table.from_arrays(
            [pa.array(c, type=f.type) for c, f in zip(cols, schema)], schema=schema))
        for c in cols:
            c.clear()
    return n


def build(job):
    wid, files = job
    opts = dict(compression="zstd", compression_level=1)   # zstd:1 : ~2x plus compact que snappy, aussi rapide
    w_pl = pq.ParquetWriter(f"{OUT}/playlist/part-{wid:02d}.parquet", PLAYLIST, **opts)
    w_tr = pq.ParquetWriter(f"{OUT}/track/part-{wid:02d}.parquet", TRACK, **opts)
    P = [[] for _ in PLAYLIST]
    T = [[] for _ in TRACK]
    n_pl = n_tr = 0

    for path in files:
        for pl in json.loads(open(path, "rb").read())["playlists"]:
            pid = pl["pid"]
            P[0].append(pid)
            P[1].append(pl["name"])
            P[2].append(pl.get("description"))
            P[3].append(pl["collaborative"] == "true")
            P[4].append(pl["modified_at"] // 86400)        # date32 = jours depuis l'epoch
            P[5].append(pl["num_tracks"])
            P[6].append(pl["num_albums"])
            P[7].append(pl["num_artists"])
            P[8].append(pl["num_edits"])
            P[9].append(pl["num_followers"])
            P[10].append(pl["duration_ms"])
            for t in pl["tracks"]:
                T[0].append(pid)
                T[1].append(t["pos"])
                T[2].append(t["track_uri"][14:])           # retire "spotify:track:"
                T[3].append(t["track_name"])
                T[4].append(t["artist_uri"][15:])
                T[5].append(t["artist_name"])
                T[6].append(t["album_uri"][14:])
                T[7].append(t["album_name"])
                T[8].append(t["duration_ms"])
        if len(T[0]) >= ROWS_PER_GROUP:
            n_tr += flush(w_tr, TRACK, T)

    n_tr += flush(w_tr, TRACK, T)
    n_pl += flush(w_pl, PLAYLIST, P)
    w_tr.close()
    w_pl.close()
    return wid, n_pl, n_tr


def main():
    files = sorted(os.path.join(SRC, f) for f in os.listdir(SRC)
                   if f.startswith("mpd.slice.") and f.endswith(".json"))
    if len(sys.argv) > 1:
        files = files[:int(sys.argv[1])]

    shutil.rmtree(OUT, ignore_errors=True)                 # reconstruction propre
    os.makedirs(f"{OUT}/playlist")
    os.makedirs(f"{OUT}/track")

    chunk = -(-len(files) // NWORKERS)
    jobs = [(i, files[i * chunk:(i + 1) * chunk]) for i in range(NWORKERS)]
    jobs = [j for j in jobs if j[1]]

    t0 = time.perf_counter()
    n_pl = n_tr = 0
    with Pool(len(jobs)) as pool:
        for _, a, b in pool.imap_unordered(build, jobs):
            n_pl += a
            n_tr += b
    wall = time.perf_counter() - t0

    src_go = sum(os.path.getsize(f) for f in files) / 2**30
    out_mo = sum(os.path.getsize(os.path.join(d, f))
                 for d, _, fs in os.walk(OUT) for f in fs) / 2**20
    print(f"  playlist : {n_pl:>12,} lignes")
    print(f"  track    : {n_tr:>12,} lignes")
    print(f"  {src_go:.1f} Go JSON -> {out_mo:,.0f} Mo Parquet "
          f"(x{src_go * 1024 / out_mo:.1f})")
    print(f"  {wall:.1f} s  ({src_go * 1024 / wall:.0f} Mo/s)")


if __name__ == "__main__":
    main()
