#!/usr/bin/env python3
"""
Branche DuckDB sur la couche silver. A lancer une fois, avant d'attaquer le gold.

Cree gold.duckdb a la racine du projet, contenant deux vues sur les Parquet :

    playlist    1 000 000 lignes
    track      66 346 428 lignes

Les vues sont des VUES, pas des copies : aucune donnee n'est dupliquee, et un
rebuild de silver/ est visible immediatement. Les chemins sont ABSOLUS, donc
les requetes fonctionnent depuis n'importe quel repertoire courant -- relancer
ce script apres un deplacement du projet.

    duckdb gold.duckdb                      # en ligne de commande
    duckdb.connect("gold.duckdb")           # en Python

Usage :  python3 setup_duckdb.py
         MPD_SILVER=/chemin/vers/silver python3 setup_duckdb.py
"""
import os
import sys

import duckdb

HERE = os.path.dirname(os.path.abspath(__file__))
SILVER = os.environ.get("MPD_SILVER") or os.path.join(HERE, "silver")
DB = os.path.join(HERE, "gold.duckdb")


def sql_str(path):
    """Litteral SQL sur mesure : le chemin contient des espaces et un '&'."""
    return "'" + path.replace("'", "''") + "'"


def main():
    if not os.path.isdir(SILVER):
        sys.exit(f"silver/ introuvable : {SILVER}\nLancez d'abord build_silver.py")

    con = duckdb.connect(DB)
    for table in ("playlist", "track"):
        pattern = os.path.join(SILVER, f"{table}.*.parquet")
        con.execute(f"CREATE OR REPLACE VIEW {table} AS "
                    f"SELECT * FROM read_parquet({sql_str(pattern)})")

    print(f"  base    : {DB}")
    print(f"  silver  : {SILVER}")
    print("  vues    :")
    for table in ("playlist", "track"):
        n = con.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        cols = con.execute(f"DESCRIBE {table}").fetchall()
        print(f"    {table:<9} {n:>12,} lignes, {len(cols)} colonnes")
    con.close()


if __name__ == "__main__":
    main()
