"""Build the Scarlet API map: every data point the WoW Forever client documents,
grouped by what it is about, with what Scarlet records and why it leaves out
the rest.

    python tools/apimap.py --docs <Blizzard_APIDocumentationGenerated> [--ui <Interface/AddOns export>] [--strict]

Writes docs/api-map.json (the data) and docs/api-map.html (the page, built
from tools/api-map.template.html with the data inlined so it opens from disk).

A "data point" is an event, or a function whose name reads state (Get, Is,
Has, Unit...) or whose documentation gives it Returns. Actions that return
nothing (Set, Open, Craft...) are listed but not counted. Recorded means the
addon registers the event or calls the function; a name listed in Baseline.lua's
CONTENT_PROBES only checks that the API exists and does not count.

Every data point in a game domain, and every one in "Undocumented", is either
recorded or has a reason in tools/coverage.json under "skip". "Interface and
other" is listed and not counted. With --ui, each API is also marked when a
file the Forever client loads calls it (forever_ui), and the undocumented
globals those files call become the "Undocumented" domain. That column is a
fact about the client; it does not decide what needs a reason.

--strict exits 1 and lists every data point that is neither recorded nor
skipped. Without it the count is printed. Skip entries for names that are now
recorded, or that match no row, are printed so they can be pruned.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "addon", "Scarlet")

# System name -> domain. Systems not listed are interface plumbing and are
# shown but not counted.
DOMAINS = {
    "Character": ["PaperDollInfo", "PlayerInfo", "PlayerLocationInfo", "SpecializationInfo", "ClassTalents",
                  "SharedTraits", "Title", "LevelSquish", "Unit", "UnitRole", "SpecializationShared",
                  "PlayerScript", "EquipmentSet", "GameRules"],
    "Combat": ["DamageMeter", "DeathRecap", "DeathInfo", "LossOfControl", "CombatLog", "CombatLogSecure",
               "CombatText", "SpellDiminishUI", "Threat", "Totem", "SwingTimer", "UnitAuras", "InstanceEncounter",
               "EncounterInfo", "EncounterEvents", "EncounterJournal", "DeathAlert", "Vehicle"],
    "Spells": ["Spell", "SpellBook", "SpellActivationOverlay", "Flyout", "ActionBar", "PetInfo", "StableInfo"],
    "World and travel": ["MapUI", "MapExplorationInfo", "AreaPoiInfo", "TaxiMap", "Vignette", "WorldStateInfo",
                         "Instance", "ZoneScript", "WeatherScript", "Minimap", "InGameNavigation", "FogOfWar",
                         "MirrorTimer", "SummonInfo", "IncomingSummon", "WorldLootObject", "ZoneAbility",
                         "RaidLocks", "ScenarioInfo"],
    "Professions": ["TradeSkillUI", "ProfessionSpecUI", "CraftingOrderUI", "SkillInfo", "ScrappingMachineUI",
                    "LegendaryCrafting"],
    "Economy and items": ["CurrencySystem", "Container", "Bank", "MerchantFrame", "AuctionHouse", "MailInfo",
                          "TradeInfo", "Loot", "LootFrame", "LootHistory", "Item", "WowTokenUI", "ItemUpgrade",
                          "ItemSocketInfo", "ItemInteractionUI", "NewItems", "GuildBank", "BlackMarketInfo",
                          "AutoLoot"],
    "Quests and NPCs": ["QuestLog", "QuestOffer", "QuestLineUI", "QuestTaskInfo", "QuestInfoSystem",
                        "GossipInfo", "Trainer", "QuestSession", "WarCampaign", "ContentTracking", "QuestHubUI",
                        "QuestItemUse", "PlayerChoice", "PlayerInteractionManager", "ItemText", "TalkingHead"],
    "Social": ["PartyInfo", "ChatInfo", "FriendList", "GuildInfo", "Club", "RecentAllies", "SocialQueue",
               "LFGInfo", "LFGList", "LFGListRoles", "DuelInfo", "Calendar", "PlayerMentorship", "BattleNet",
               "ClubFinderInfo", "RecruitAFriend", "SocialUI", "PingManager"],
    "Progress": ["AchievementInfo", "AchievementTelemetry", "ReputationInfo", "MajorFactionsUI",
                 "WeeklyRewards", "ChallengeModeInfo", "MythicPlusInfo", "DelvesUI", "SeasonInfo",
                 "PerksActivities", "TimerunningUI", "ChromieTimeInfo"],
    "Collections": ["MountJournal", "PetJournalInfo", "ToyBoxInfo", "HeirloomInfo", "TransmogrifyCollection",
                    "TransmogrifySets", "BattlePet", "PetBattles", "TransmogOutfitInfo", "Transmogrify"],
    "PvP": ["PvpInfo"],
}
SYSTEM_DOMAIN = {s: d for d, ss in DOMAINS.items() for s in ss}
OTHER = "Interface and other"
UNDOCUMENTED = "Undocumented"
READ = re.compile(r"^(Get|Is|Has|Are|Does|Can|Should|Unit|Calculate|Find|Num|Count|Was|Will|Request)(?![a-z])")
COLUMNS = ["domain", "system", "kind", "name", "fields", "read", "tracked", "forever_ui", "skip"]


def parse_docs(docs):
    systems = []
    for f in sorted(os.listdir(docs)):
        s = open(os.path.join(docs, f), encoding="utf-8", errors="ignore").read()
        m = re.search(r'Name = "(\w+)",\n\tType = "System",(?:\n\tNamespace = "([\w.]+)",)?', s)
        if not m:
            continue
        name, ns = m.group(1), m.group(2) or ""
        apis = []
        for fm in re.finditer(r'\{\n\t\t\tName = "(\w+)",\n\t\t\tType = "Function",(.*?)\n\t\t\},\n', s, re.S):
            body = fm.group(2)
            ret = re.search(r"Returns =\s*\{(.*?)\n\t\t\t\}", body, re.S)
            fields = re.findall(r'Name = "(\w+)"', ret.group(1)) if ret else []
            apis.append({"k": "f", "n": (ns + "." if ns else "") + fm.group(1), "b": fm.group(1),
                         "d": fields, "r": bool(READ.match(fm.group(1))) or bool(fields)})
        for em in re.finditer(r'\{\n\t\t\tName = "(\w+)",\n\t\t\tType = "Event",\n\t\t\tLiteralName = "(\w+)",(.*?)\n\t\t\},\n', s, re.S):
            fields = re.findall(r'Name = "(\w+)"', em.group(3))
            apis.append({"k": "e", "n": em.group(2), "b": em.group(2), "d": fields, "r": True})
        if apis:
            systems.append({"system": name, "ns": ns, "apis": apis})
    return systems


def content_probes():
    """Names in Baseline.lua's CONTENT_PROBES table: "e:EVENT", "f:C_Name.Function", "f:Global"."""
    path = os.path.join(ADDON, "Baseline.lua")
    if not os.path.isfile(path):
        return set()
    src = open(path, encoding="utf-8").read()
    src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    src = re.sub(r"--[^\n]*", "", src)
    m = re.search(r"\bCONTENT_PROBES\s*=\s*\{", src)
    if not m:
        return set()
    depth, i = 1, m.end()
    while i < len(src) and depth:
        depth += {"{": 1, "}": -1}.get(src[i], 0)
        i += 1
    return {name for _, name in re.findall(r"[\"']([ef]):([\w.]+)[\"']", src[m.end():i])}


def addon_usage():
    src = ""
    for f in sorted(os.listdir(ADDON)):
        if f.endswith(".lua"):
            src += open(os.path.join(ADDON, f), encoding="utf-8").read() + "\n"
    # Strip comments so names in prose do not count.
    src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    src = re.sub(r"--[^\n]*", "", src)
    events = set(re.findall(r"\bH\.([A-Z][A-Z0-9_]+)\b", src))
    events |= set(re.findall(r'"([A-Z][A-Z0-9_]{3,})"', src)) & set(re.findall(r"\b([A-Z][A-Z0-9_]+)\b", src))
    funcs = set()
    for ns, fn in re.findall(r"\b(C_\w+)\.(\w+)", src):
        funcs.add(ns + "." + fn)
    # Local aliases: local DM = C_DamageMeter ... DM.Fn
    for alias, ns in re.findall(r"local (\w+) = (C_\w+)\b", src):
        for fn in re.findall(r"\b%s\.(\w+)" % re.escape(alias), src):
            funcs.add(ns + "." + fn)
    globals_ = set(re.findall(r"(?<![:.\w])([A-Z][A-Za-z0-9]+)\s*\(", src))
    globals_ |= set(re.findall(r'(?:Call|First|Second|AttackPower|BestSchool)\("([A-Z]\w+)"', src))
    globals_ |= set(re.findall(r"_G\.([A-Z]\w+)", src))
    globals_ |= set(re.findall(r"pcall\(([A-Z]\w+)", src))
    probes = content_probes()
    return events - probes, funcs - probes, globals_ - probes, probes


# Forever's game type is "camelot". It is part of the mainline family:
# mainline-only addons ship camelot overrides, and files that must not load
# in Forever say ExcludeLoadGameType camelot. "standard" and the classic
# types do not include it. [Family] is the Mainline folder, [Game] Camelot.
FOREVER_TYPES = {"camelot", "mainline"}


def _allows(tags, key):
    m = re.search(key + r"[:\s]+([\w ,]+)", tags, re.I)
    return None if not m else {t.strip().lower() for t in re.split(r"[,\s]+", m.group(1)) if t.strip()}


def forever_files(ui):
    """Lua files the Forever client loads, read from every addon's TOC."""
    files = []
    for addon in sorted(os.listdir(ui)):
        d = os.path.join(ui, addon)
        tocs = [f for f in os.listdir(d) if f.endswith(".toc")] if os.path.isdir(d) else []
        if not tocs or addon == "Blizzard_APIDocumentationGenerated":
            continue
        toc = open(os.path.join(d, tocs[0]), encoding="utf-8", errors="ignore").read()
        head = "\n".join(l for l in toc.splitlines() if l.startswith("##"))
        allow, exclude = _allows(head, "## AllowLoadGameType"), _allows(head, "## ExcludeLoadGameType")
        load = _allows(head, "## AllowLoad")
        if (allow and not allow & FOREVER_TYPES) or (exclude and "camelot" in exclude) or load == {"glue"}:
            continue
        for line in toc.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"(\S+\.lua)\s*(.*)$", line, re.I)
            if not m:
                continue
            path, tags = m.group(1), m.group(2)
            fa, fe = _allows(tags, r"\[AllowLoadGameType"), _allows(tags, r"\[ExcludeLoadGameType")
            if (fa and not fa & FOREVER_TYPES) or (fe and "camelot" in fe):
                continue
            path = path.replace("[Family]", "Mainline").replace("[Game]", "Camelot").replace("\\", os.sep)
            full = os.path.join(d, path)
            if os.path.isfile(full):
                files.append(full)
    return files


def ui_scan(ui):
    """What the Forever client's Lua calls: (called names, bare global calls, names any UI Lua defines)."""
    if not ui:
        return None
    blob = "\n".join(open(f, encoding="utf-8", errors="ignore").read() for f in forever_files(ui))
    code = re.sub(r"--\[(=*)\[.*?\]\1\]", "", blob, flags=re.S)
    code = re.sub(r"--[^\n]*", "", code)
    called = set(re.findall(r"\b((?:C_\w+\.)?[A-Z]\w+)\s*\(", blob)) | set(re.findall(r'"([A-Z][A-Z0-9_]{3,})"', blob))
    bare = set(re.findall(r"(?<![:.\w])([A-Z]\w*)\s*\(", code))
    defined = set()
    for root, _, names in os.walk(ui):
        for n in names:
            if n.endswith(".lua"):
                text = open(os.path.join(root, n), encoding="utf-8", errors="ignore").read()
                defined |= set(re.findall(r"\bfunction\s+([A-Za-z_]\w*)\s*\(", text))
                defined |= set(re.findall(r"(?<![.:\w])([A-Za-z_]\w*)\s*=\s*function\b", text))
                defined |= set(re.findall(r"(?m)^([A-Za-z_]\w*)\s*=[^=]", text))
    return called, bare, defined


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs", required=True)
    ap.add_argument("--ui")
    ap.add_argument("--build", default="1.60.1.70959")
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()
    systems = parse_docs(a.docs)
    events, funcs, globals_, probes = addon_usage()
    scan = ui_scan(a.ui)
    ui = scan[0] if scan else None
    cov_path = os.path.join(ROOT, "tools", "coverage.json")
    skips = json.load(open(cov_path, encoding="utf-8")).get("skip", {}) if os.path.exists(cov_path) else {}
    rows = []
    for sy in systems:
        dom = SYSTEM_DOMAIN.get(sy["system"], OTHER)
        for x in sy["apis"]:
            if x["k"] == "e":
                tracked = x["n"] in events
            elif sy["ns"]:
                tracked = x["n"] in funcs
            else:
                tracked = x["b"] in globals_
            live = None if ui is None else (x["n"] in ui or x["b"] in ui)
            rows.append([dom, sy["system"], x["k"], x["n"], " ".join(x["d"][:12]), int(x["r"]), int(tracked),
                         None if live is None else int(live), "" if tracked else skips.get(x["n"], "")])
    documented = {x["b"] for sy in systems for x in sy["apis"] if x["k"] == "f" and not sy["ns"]}
    extra = []
    if scan:
        extra = sorted(g for g in scan[1] if READ.match(g) and g not in documented and g not in scan[2])
        for g in extra:
            tracked = g in globals_
            rows.append([UNDOCUMENTED, UNDOCUMENTED, "f", g, "", 1, int(tracked), 1, "" if tracked else skips.get(g, "")])
    summary = {}
    undecided = []
    for r in rows:
        s = summary.setdefault(r[0], {"apis": 0, "points": 0, "tracked": 0, "skipped": 0, "undecided": 0,
                                      "live": 0, "liveTracked": 0})
        s["apis"] += 1
        if not r[5]:
            continue
        s["points"] += 1
        s["tracked"] += r[6]
        s["skipped"] += int(bool(r[8]))
        if r[7]:
            s["live"] += 1
            s["liveTracked"] += r[6]
        if r[0] != OTHER and not r[6] and not r[8]:
            s["undecided"] += 1
            undecided.append(r)
    rows.sort(key=lambda r: (r[0] == OTHER, r[0], -r[6], -r[5], r[3]))
    names = {r[3] for r in rows}
    tracked_names = {r[3] for r in rows if r[6]}
    dead = sorted(k for k in skips if k in tracked_names)
    unknown = sorted(k for k in skips if k not in names)
    out = os.path.join(ROOT, "docs", "api-map.json")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write('{"build":%s,"columns":%s,"summary":%s,"undocumented":%s,"rows":[\n' % (
            json.dumps(a.build), json.dumps(COLUMNS), json.dumps(summary),
            json.dumps(sorted(r[3] for r in rows if r[0] == UNDOCUMENTED and r[6]))))
        fh.write(",\n".join(json.dumps(r, separators=(",", ":")) for r in rows))
        fh.write("\n]}\n")
    # The page carries its data inline so it opens from disk; a browser will
    # not fetch a sibling file over file://. "</" is escaped for the script tag.
    page = open(os.path.join(ROOT, "tools", "api-map.template.html"), encoding="utf-8").read()
    payload = open(out, encoding="utf-8").read().replace("</", "<\\/")
    with open(os.path.join(ROOT, "docs", "api-map.html"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("<!doctype html>\n<meta charset=\"utf-8\">\n"
                 "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n")
        fh.write(page.replace("/*DATA*/", payload))
    keys = ["apis", "points", "tracked", "skipped", "undecided", "live", "liveTracked"]
    tot = {k: sum(v[k] for d, v in summary.items() if d != OTHER) for k in keys}
    print(json.dumps(tot))
    for d, v in sorted(summary.items()):
        print(f"{d:22} {v}")
    if probes:
        print("content probes (not counted as recorded):", len(probes))
    for label, items in (("skip entries for names that are now recorded", dead),
                         ("skip entries that match no row", unknown)):
        if items:
            print(f"{label} ({len(items)}):")
            for k in items:
                print("  ", k)
    print("undecided data points:", len(undecided))
    if a.strict and undecided:
        for r in undecided:
            print(f"  {r[0]} | {r[1]} | {r[2]} | {r[3]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
