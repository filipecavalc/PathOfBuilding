"""Price bulk Path of Exile 1 items on poe.ninja (public, no login): currency, fragments, divination cards,
essences, gems, uniques. Standard library only.

Usage:
  python scripts/ninja.py price --league Covens --name "Arc" --class "Skill Gems" --level 20 --quality 20 --corrupted
  python scripts/ninja.py price --league Covens --name "Divine Orb"
  python scripts/ninja.py rates --league Covens

`--class` is the item's "Item Class" line (trade_price returns it as bulk.kind); it picks the one poe.ninja category
to download. Without it the script tries the exchange categories, then the item ones, and stops at the first exact
name match. Output is JSON. poe.ninja shows asking prices from listings (or the Currency Exchange), not sales.
"""
import argparse
import json
import sys
import urllib.request
from urllib.error import HTTPError, URLError
from urllib.parse import quote

HOST = "https://poe.ninja"
USER_AGENT = "poe1-pricecheck/2.0"

# Categories with data in Covens (checked 2026-11-17).
EXCHANGE_TYPES = ["Currency", "Fragment", "DivinationCard", "Essence", "Fossil", "Oil", "Resonator", "DeliriumOrb",
                  "Omen", "Tattoo", "Artifact", "AllflameEmber", "Runegraft", "Thread"]
ITEM_TYPES = ["SkillGem", "UniqueAccessory", "UniqueArmour", "UniqueWeapon", "UniqueJewel", "UniqueFlask", "UniqueMap",
              "UniqueRelic", "UniqueTincture", "ClusterJewel", "Map", "BlightedMap", "BlightRavagedMap", "Invitation", "Beast"]

# Item Class line -> where to look first.
CLASS_TYPES = [
    ("Gem", ["item:SkillGem"]),
    ("Divination", ["exchange:DivinationCard"]),
    ("Fragment", ["exchange:Fragment", "item:Invitation"]),
    ("Maps", ["item:Map", "item:BlightedMap", "item:BlightRavagedMap", "item:UniqueMap"]),
    ("Tattoo", ["exchange:Tattoo"]),
    ("Omen", ["exchange:Omen"]),
    ("Currency", ["exchange:" + t for t in EXCHANGE_TYPES]),
    ("Ring", ["item:UniqueAccessory"]), ("Amulet", ["item:UniqueAccessory"]), ("Belt", ["item:UniqueAccessory"]),
    ("Jewel", ["item:UniqueJewel", "item:ClusterJewel"]), ("Flask", ["item:UniqueFlask"]),
]
ARMOUR_CLASSES = ("Helmet", "Body Armour", "Gloves", "Boots", "Shield", "Quiver")


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def url_for(league, kind, t):
    if kind == "exchange":
        return f"{HOST}/poe1/api/economy/exchange/current/overview?league={quote(league)}&type={t}"
    return f"{HOST}/poe1/api/economy/stash/current/item/overview?league={quote(league)}&type={t}"


def candidates_for(item_class):
    if item_class:
        for key, types in CLASS_TYPES:
            if key.lower() in item_class.lower():
                return types
        if any(c.lower() in item_class.lower() for c in ARMOUR_CLASSES):
            return ["item:UniqueArmour"]
        return ["item:UniqueWeapon"]
    return ["exchange:" + t for t in EXCHANGE_TYPES] + ["item:" + t for t in ITEM_TYPES]


def rows(league, kind, t):
    try:
        d = get(url_for(league, kind, t))
    except HTTPError as e:
        if e.code == 404:
            return []
        raise
    if kind == "exchange":
        names = {i["id"]: i["name"] for i in d.get("items", [])}
        return [{"name": names.get(l["id"], l["id"]), "chaos": l.get("primaryValue"),
                 "volume_chaos": l.get("volumePrimaryValue")} for l in d.get("lines", [])]
    out = []
    for l in d.get("lines", []):
        out.append({k: l[k] for k in ("name", "baseType", "variant", "links", "gemLevel", "gemQuality", "corrupted",
                                       "mapTier", "levelRequired", "chaosValue", "divineValue", "listingCount") if k in l})
        out[-1]["chaos"] = l.get("chaosValue")
    return out


def pick_gem(found, level, quality, corrupted):
    def score(r):
        s = 0
        if level is not None:
            s += abs((r.get("gemLevel") or 0) - level) * 10
        if quality is not None:
            s += abs((r.get("gemQuality") or 0) - quality)
        if corrupted is not None:
            s += 0 if bool(r.get("corrupted")) == corrupted else 50
        return s
    return sorted(found, key=score)


def price(league, name, item_class=None, level=None, quality=None, corrupted=None):
    name_l = name.lower().strip()
    tried, partial = [], []
    for entry in candidates_for(item_class):
        kind, t = entry.split(":", 1)
        tried.append(t)
        found = rows(league, kind, t)
        exact = [r for r in found if (r.get("name") or "").lower() == name_l]
        if exact:
            if t == "SkillGem":
                exact = pick_gem(exact, level, quality, corrupted)
            return {"league": league, "category": t, "match": "exact", "best": exact[0], "variants": exact[:6],
                    "note": "poe.ninja: asking prices (listings) or Currency Exchange, not sales; for uniques it is the floor of the variant."}
        partial += [dict(r, category=t) for r in found if name_l in (r.get("name") or "").lower()]
    return {"league": league, "match": "partial" if partial else "none", "results": partial[:10], "tried": tried}


def rates(league):
    d = get(url_for(league, "exchange", "Currency"))
    names = {i["id"]: i["name"] for i in d.get("items", [])}
    return {"league": league, "source": "poe.ninja exchange (Currency Exchange)",
            "chaos_per": {l["id"]: l["primaryValue"] for l in d.get("lines", [])},
            "names": {k: v for k, v in names.items() if k in ("divine", "exalted", "chaos", "mirror")}}


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["price", "rates"])
    ap.add_argument("--league", required=True)
    ap.add_argument("--name")
    ap.add_argument("--class", dest="item_class")
    ap.add_argument("--level", type=int)
    ap.add_argument("--quality", type=int)
    ap.add_argument("--corrupted", action="store_true", default=None)
    a = ap.parse_args()
    try:
        if a.cmd == "rates":
            out = rates(a.league)
        else:
            if not a.name:
                raise SystemExit("Use --name.")
            out = price(a.league, a.name, a.item_class, a.level, a.quality, a.corrupted)
    except (HTTPError, URLError) as e:
        out = {"error": f"poe.ninja did not answer: {e}"}
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
