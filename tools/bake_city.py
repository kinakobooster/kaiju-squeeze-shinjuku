"""OSM (Overpass JSON) -> data/city.json for the Godot project.

Coordinates: origin = JR Shinjuku station, x = east [m], z = south [m] (Godot -Z is north).
Building heights: OSM `height` > `building:levels` * 3.5 > heuristic guess.
"""
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LAT0, LON0 = 35.6896, 139.7006
KX = 111320.0 * math.cos(math.radians(LAT0))
KZ = 110540.0

# Landmark heights (m) in case OSM lacks them.
KNOWN = {
    "モード学園コクーンタワー": 203.65,
    "新宿パークタワー": 235.0,
    "東京オペラシティタワー": 234.4,
    "新宿三井ビルディング": 225.0,
    "新宿センタービル": 222.95,
    "住友不動産新宿オークタワー": 199.0,
    "新宿住友ビル": 210.3,
    "SOMPO美術館": 200.0,
    "損保ジャパン本社ビル": 200.0,
    "新宿アイランドタワー": 189.0,
    "新宿野村ビル": 209.9,
    "ハイアットリージェンシー東京": 112.0,
    "東急歌舞伎町タワー": 225.0,
}


# Overrides for OSM values that look wrong at kaiju scale (twin-tower top of Tocho).
FORCE = {"東京都庁舎 第一本庁舎": 243.0}


def proj(lat, lon):
    return ((lon - LON0) * KX, -(lat - LAT0) * KZ)


def area(poly):
    a = 0.0
    for i in range(len(poly)):
        x1, z1 = poly[i]
        x2, z2 = poly[(i + 1) % len(poly)]
        a += x1 * z2 - x2 * z1
    return a * 0.5


def simplify(poly, eps=0.6):
    """Drop near-duplicate and near-collinear points."""
    out = []
    for p in poly:
        if not out or math.dist(out[-1], p) > eps:
            out.append(p)
    if len(out) > 1 and math.dist(out[0], out[-1]) <= eps:
        out.pop()
    changed = True
    while changed and len(out) > 3:
        changed = False
        for i in range(len(out)):
            a, b, c = out[i - 1], out[i], out[(i + 1) % len(out)]
            cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
            if abs(cross) < eps * max(math.dist(a, c), 0.01):
                out.pop(i)
                changed = True
                break
    return out


def parse_h(v):
    try:
        return float(str(v).replace("m", "").strip().split(";")[0])
    except ValueError:
        return None


def guess_height(rng, a, cx, cz):
    west = -1100 < cx < -330 and -700 < cz < 350  # Nishi-Shinjuku skyscraper district
    if a < 80:
        h = rng.uniform(6, 13)
    elif a < 300:
        h = rng.uniform(9, 26)
    elif a < 1000:
        h = rng.uniform(14, 42)
    elif a < 3000:
        h = rng.uniform(20, 60)
    else:
        h = rng.uniform(25, 70)
    if west and a > 1500:
        h = rng.uniform(60, 160)
    return round(h, 1)


def main():
    bdata = json.load(open(os.path.join(HERE, "data", "shinjuku_osm.json")))
    ldata = json.load(open(os.path.join(HERE, "data", "shinjuku_lines.json")))
    nodes = {}
    for d in (bdata, ldata):
        for e in d["elements"]:
            if e["type"] == "node":
                nodes[e["id"]] = proj(e["lat"], e["lon"])

    buildings = []
    for e in bdata["elements"]:
        if e["type"] != "way" or "tags" not in e:
            continue
        t = e["tags"]
        if t.get("building") in ("roof", "no", "construction"):
            continue
        pts = [nodes[n] for n in e["nodes"] if n in nodes]
        poly = simplify(pts)
        if len(poly) < 3:
            continue
        a = area(poly)
        if abs(a) < 15:
            continue
        if a < 0:  # make winding consistent (counter-clockwise in x/z as stored)
            poly.reverse()
        cx = sum(p[0] for p in poly) / len(poly)
        cz = sum(p[1] for p in poly) / len(poly)
        name = t.get("name", "")
        h = parse_h(t["height"]) if "height" in t else None
        if name in FORCE:
            h = FORCE[name]
        if h is None and name in KNOWN:
            h = KNOWN[name]
        if h is None and "building:levels" in t:
            lv = parse_h(t["building:levels"])
            if lv:
                h = lv * 3.5
        if h is None:
            h = guess_height(random.Random(e["id"]), abs(a), cx, cz)
        h = max(4.0, min(h, 260.0))
        flat = []
        for x, z in poly:
            flat += [round(x, 1), round(z, 1)]
        buildings.append({"n": name, "h": h, "p": flat})

    widths = {"motorway": 22, "trunk": 20, "primary": 18, "secondary": 14, "tertiary": 10,
              "motorway_link": 10, "trunk_link": 10, "primary_link": 10,
              "residential": 6, "unclassified": 6, "pedestrian": 6, "service": 4}
    roads, rails, parks, water = [], [], [], []
    for e in ldata["elements"]:
        if e["type"] != "way" or "tags" not in e:
            continue
        t = e["tags"]
        pts = [nodes[n] for n in e["nodes"] if n in nodes]
        if len(pts) < 2:
            continue
        flat = []
        for x, z in pts:
            flat += [round(x, 1), round(z, 1)]
        if "highway" in t:
            if t.get("tunnel") == "yes" or t.get("layer", "0").startswith("-"):
                continue
            roads.append({"w": widths.get(t["highway"], 6), "p": flat})
        elif t.get("railway") == "rail":
            if t.get("tunnel") == "yes":
                continue
            rails.append({"p": flat})
        elif len(pts) >= 4:
            poly = simplify(pts)
            if len(poly) < 3:
                continue
            if area(poly) < 0:
                poly.reverse()
            flat = []
            for x, z in poly:
                flat += [round(x, 1), round(z, 1)]
            (water if t.get("natural") == "water" else parks).append({"p": flat})

    out = {"origin": [LAT0, LON0], "buildings": buildings, "roads": roads,
           "rails": rails, "parks": parks, "water": water,
           "attribution": "© OpenStreetMap contributors (ODbL)"}
    os.makedirs(os.path.join(ROOT, "data"), exist_ok=True)
    path = os.path.join(ROOT, "data", "city.json")
    with open(path, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    hs = sorted((b["h"], b["n"]) for b in buildings)[-12:]
    print(f"buildings={len(buildings)} roads={len(roads)} rails={len(rails)} parks={len(parks)} water={len(water)}")
    print("tallest:", hs)
    print("bytes:", os.path.getsize(path))


if __name__ == "__main__":
    sys.exit(main())
