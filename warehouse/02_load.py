#!/usr/bin/env python3
"""
ENTREPOT MPD - 02. Chargement des 31 Go de JSON vers le staging Postgres.

Aucun fichier intermediaire : chaque worker pousse du CSV directement dans un
`psql \\copy ... FROM STDIN`.

DEUX PIEGES DE LA SOURCE, ET LEUR PARADE
----------------------------------------
1. ANTISLASH  -  16 698 valeurs en contiennent ("Axwell /\\ Ingrosso").
   L'antislash est le caractere d'echappement du format `text` de COPY :
   il corromprait silencieusement les donnees. => FORMAT csv obligatoire,
   qui n'accorde aucun sens special a l'antislash et cite les 2 descriptions
   contenant un saut de ligne.

2. LA SENTINELLE NULL  -  un artiste du catalogue se nomme LITTERALEMENT "\\N".
   Toute sentinelle textuelle est donc suspecte. Parade en deux temps :
     - FORCE_NOT_NULL sur toutes les colonnes texte : plus aucune chaine
       ne peut etre reinterpretee en NULL par COPY ;
     - un booleen explicite has_description porte l'information "champ absent",
       au lieu de la coder dans la valeur elle-meme.

Usage :  python3 02_load.py [items] [tracks] [playlists]     (defaut : tout)
"""
import csv, io, json, os, subprocess, sys, time
from multiprocessing import Pool

# Dossier des slices JSON : ../data par rapport a ce script, surchargeable
# par la variable d'environnement MPD_DATA.
DATA = os.environ.get("MPD_DATA") or os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "data"))
DB = "mpd"
NWORKERS = 8

# (table, liste explicite des colonnes, colonnes texte protegees par FORCE_NOT_NULL)
# La liste de colonnes est EXPLICITE a dessein : elle rend le chargement immunise
# contre tout ajout ou reordonnancement ulterieur de colonne dans le staging.
COPIES = {
    "items": ("staging.stg_item",
              "(playlist_id, pos, track_id)",
              "(track_id)"),
    "tracks": ("staging.stg_track",
               "(track_id, track_name, artist_id, artist_name, album_id, album_name, duration_ms)",
               "(track_name, artist_name, album_name)"),
    "playlists": ("staging.stg_playlist",
                  "(playlist_id, name, description, has_description, collaborative, modified_at,"
                  " num_tracks, num_albums, num_artists, num_edits, num_followers, duration_ms)",
                  "(name, description)"),
}


def start_copy(key):
    table, cols, force = COPIES[key]
    sql = f"\\copy {table} {cols} FROM STDIN WITH (FORMAT csv, FORCE_NOT_NULL {force})"
    p = subprocess.Popen(
        ["psql", "-d", DB, "-q", "-v", "ON_ERROR_STOP=1",
         "-c", "SET synchronous_commit = off;", "-c", sql],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
    )
    stream = io.TextIOWrapper(p.stdin, encoding="utf-8", newline="", write_through=False)
    return p, stream


def close_copy(p, stream, label):
    stream.flush(); stream.close()
    if p.wait() != 0:
        sys.stderr.write(f"ECHEC COPY {label}\n")
        raise SystemExit(1)


def worker(job):
    wid, files, targets = job
    handles = {k: start_copy(k) for k in targets}
    w_i = handles["items"][1] if "items" in handles else None
    w_t = csv.writer(handles["tracks"][1], lineterminator="\n") if "tracks" in handles else None
    w_p = csv.writer(handles["playlists"][1], lineterminator="\n") if "playlists" in handles else None

    seen = set()          # dedoublonnage local des pistes ; le global se fait en SQL
    n_items = n_desc = 0
    buf = []
    per_file = []         # (nom, secondes, octets) pour la mesure de debit

    for path in files:
        t_file = time.perf_counter()
        nbytes = os.path.getsize(path)
        doc = json.loads(open(path, "rb").read())
        for pl in doc["playlists"]:
            pid = pl["pid"]
            if w_p is not None:
                desc = pl.get("description")
                if desc is not None:
                    n_desc += 1
                w_p.writerow([
                    pid, pl["name"],
                    desc if desc is not None else "",       # valeur brute, jamais reinterpretee
                    desc is not None,                       # has_description : l'info d'absence
                    pl["collaborative"], pl["modified_at"],
                    pl["num_tracks"], pl["num_albums"], pl["num_artists"],
                    pl["num_edits"], pl["num_followers"], pl["duration_ms"],
                ])
            for t in pl["tracks"]:
                tid = t["track_uri"][14:]                   # retire "spotify:track:"
                if w_i is not None:
                    # ni virgule ni guillemet possibles ici (entiers + base62) :
                    # ecriture directe, bien plus rapide que csv.writer
                    buf.append(f"{pid},{t['pos']},{tid}\n")
                    if len(buf) >= 65536:
                        w_i.write("".join(buf)); buf.clear()
                n_items += 1
                if w_t is not None and tid not in seen:
                    seen.add(tid)
                    w_t.writerow([tid, t["track_name"],
                                  t["artist_uri"][15:], t["artist_name"],
                                  t["album_uri"][14:], t["album_name"],
                                  t["duration_ms"]])
        per_file.append((os.path.basename(path), time.perf_counter() - t_file, nbytes))

    if w_i is not None and buf:
        w_i.write("".join(buf))

    for k, (p, s) in handles.items():
        close_copy(p, s, k)
    return wid, len(files), n_items, len(seen), n_desc, per_file


def main():
    targets = [a for a in sys.argv[1:] if a in COPIES] or list(COPIES)
    files = sorted(os.path.join(DATA, f) for f in os.listdir(DATA)
                   if f.startswith("mpd.slice.") and f.endswith(".json"))
    # blocs CONTIGUS : chaque worker couvre une plage de playlist_id, ce qui
    # laisse stg_item quasi trie et allege le tri final du chargement des faits.
    chunk = (len(files) + NWORKERS - 1) // NWORKERS
    jobs = [(i, files[i * chunk:(i + 1) * chunk], targets) for i in range(NWORKERS)]
    jobs = [j for j in jobs if j[1]]

    print(f"Cibles : {', '.join(targets)}")
    t0 = time.perf_counter()
    tot_i = tot_d = 0
    allf = []
    with Pool(len(jobs)) as pool:
        for wid, nf, ni, nt, nd, pf in pool.imap_unordered(worker, jobs):
            tot_i += ni; tot_d += nd; allf += pf
            print(f"  worker {wid}: {nf} slices | {ni:,} items | {nt:,} pistes locales", flush=True)
    wall = time.perf_counter() - t0

    d = sorted(x[1] for x in allf)
    octets = sum(x[2] for x in allf)
    n = len(d)
    print(f"\n{tot_i:,} lignes-pistes | {tot_d:,} descriptions presentes")
    print("=" * 62)
    print(f"  Fichiers traites      : {n:,}   ({octets/2**30:.1f} Go)")
    print(f"  Duree totale (mur)    : {wall:.1f} s")
    print(f"  Workers en parallele  : {len(jobs)}")
    print("-" * 62)
    print(f"  Debit effectif        : {wall/n*1000:.1f} ms / fichier"
          f"   ({octets/2**20/wall:.0f} Mo/s)")
    print(f"  Cout unitaire reel    : {sum(d)/n:.2f} s / fichier  (temps passe"
          f" dans un worker)")
    print(f"     mediane            : {d[n//2]:.2f} s")
    print(f"     min / max          : {d[0]:.2f} s / {d[-1]:.2f} s")
    print(f"     p95                : {d[int(n*0.95)]:.2f} s")
    print("=" * 62)


if __name__ == "__main__":
    main()
