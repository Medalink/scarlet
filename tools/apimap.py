"""Build the Scarlet API map: every data API the WoW Forever client documents,
grouped by what it is about, with what Scarlet already records.

    python tools/apimap.py --docs <Blizzard_APIDocumentationGenerated> [--ui <Interface/AddOns export>]

Writes docs/api-map.json (the data) and docs/api-map.html (the page, built
from tools/api-map.template.html with the data inlined so it opens from disk).

A "data point" is an event, or a function that reads state (Get, Is, Has,
Unit...). Actions (Set, Open, Craft...) are listed but not counted. Tracked
means the addon registers the event or calls the function. With --ui, each
API is also marked when the Forever client's own UI code calls it, which is
the best sign it is live in Forever rather than only documented.
"""
import argparse
import json
import os
import re

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
READ = re.compile(r"^(Get|Is|Has|Are|Does|Can|Should|Unit|Calculate|Find|Num|Count|Was|Will|Request)")


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
                         "d": fields, "r": bool(READ.match(fm.group(1)))})
        for em in re.finditer(r'\{\n\t\t\tName = "(\w+)",\n\t\t\tType = "Event",\n\t\t\tLiteralName = "(\w+)",(.*?)\n\t\t\},\n', s, re.S):
            fields = re.findall(r'Name = "(\w+)"', em.group(3))
            apis.append({"k": "e", "n": em.group(2), "b": em.group(2), "d": fields, "r": True})
        if apis:
            systems.append({"system": name, "ns": ns, "apis": apis})
    return systems


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
    return events, funcs, globals_


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


def ui_calls(ui):
    if not ui:
        return None
    text = [open(f, encoding="utf-8", errors="ignore").read() for f in forever_files(ui)]
    blob = "\n".join(text)
    return set(re.findall(r"\b((?:C_\w+\.)?[A-Z]\w+)\s*\(", blob)) | set(re.findall(r'"([A-Z][A-Z0-9_]{3,})"', blob))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs", required=True)
    ap.add_argument("--ui")
    ap.add_argument("--build", default="1.60.1.70959")
    a = ap.parse_args()
    systems = parse_docs(a.docs)
    events, funcs, globals_ = addon_usage()
    ui = ui_calls(a.ui)
    # Decisions from coverage waves: APIs judged not worth recording, with why.
    cov_path = os.path.join(ROOT, "tools", "coverage.json")
    skips = json.load(open(cov_path, encoding="utf-8")).get("skip", {}) if os.path.exists(cov_path) else {}
    rows, summary = [], {}
    for sy in systems:
        dom = SYSTEM_DOMAIN.get(sy["system"], "Interface and other")
        for x in sy["apis"]:
            if x["k"] == "e":
                tracked = x["n"] in events
            elif sy["ns"]:
                tracked = x["n"] in funcs
            else:
                tracked = x["b"] in globals_
            live = None if ui is None else (x["n"] in ui or x["b"] in ui)
            skip = "" if tracked else skips.get(x["n"], "")
            rows.append([dom, sy["system"], x["k"], x["n"], " ".join(x["d"][:12]), int(x["r"]), int(tracked),
                         None if live is None else int(live), skip])
            s = summary.setdefault(dom, {"apis": 0, "points": 0, "tracked": 0, "live": 0, "liveTracked": 0,
                                         "skipped": 0})
            s["apis"] += 1
            if x["r"]:
                s["points"] += 1
                s["tracked"] += int(tracked)
                if live:
                    s["live"] += 1
                    s["liveTracked"] += int(tracked)
                    s["skipped"] += int(bool(skip))
    rows.sort(key=lambda r: (r[0] == "Interface and other", r[0], -r[6], -r[5], r[3]))
    # Globals the addon uses that the docs do not list (older APIs Forever still has).
    documented = {r[3] for r in rows} | {r[3].split(".")[-1] for r in rows}
    extra = sorted(g for g in globals_ if g not in documented and (ui is None or g in ui)
                   and READ.match(g))
    data = {"build": a.build,
            "summary": summary, "rows": rows, "undocumented": extra,
            "columns": ["domain", "system", "kind", "name", "fields", "read", "tracked", "forever_ui", "skip"]}
    out = os.path.join(ROOT, "docs", "api-map.json")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write('{"build":%s,"columns":%s,"summary":%s,"undocumented":%s,"rows":[\n' % (
            json.dumps(data["build"]), json.dumps(data["columns"]), json.dumps(summary), json.dumps(extra)))
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
    tot = {k: sum(v[k] for d, v in summary.items() if d != "Interface and other") for k in
           ["apis", "points", "tracked", "live", "liveTracked", "skipped"]}
    print(json.dumps(tot), "undocumented globals used:", len(extra))
    for d, v in sorted(summary.items()):
        print(f"{d:22} {v}")


if __name__ == "__main__":
    main()
