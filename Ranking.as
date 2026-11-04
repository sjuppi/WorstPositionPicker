const uint64 CacheDurationMs = 30 * 60 * 1000;
const string TotalPlayersField = "length";

class WorstCandidate
{
    string campaign;
    string mapUid;
    string zone;
    int position;
    int totalPlayers;
}

array<WorstCandidate@> g_worstMaps;
uint g_scanned = 0;
bool g_fetching = false;
bool g_scanFailed = false;
bool g_cacheValid = false;
uint64 g_cacheCreatedAt = 0;
Regions g_cachedRegion;
RankingMode g_cachedRankingMode;
CampaignSelection g_cachedCampaignSelection;
int g_cachedCampaignOffset = 0;
string g_lastObservedMapUid;

bool CacheMatchesSettings()
{
    return g_cacheValid &&
        g_cachedRegion == Setting_Region &&
        g_cachedRankingMode == Setting_RankingMode &&
        g_cachedCampaignSelection == Setting_CampaignSelection &&
        g_cachedCampaignOffset == Setting_CampaignOffset;
}

bool CacheIsFresh()
{
    return CacheMatchesSettings() && Time::Now - g_cacheCreatedAt < CacheDurationMs;
}

void SaveCacheSettings()
{
    g_cachedRegion = Setting_Region;
    g_cachedRankingMode = Setting_RankingMode;
    g_cachedCampaignSelection = Setting_CampaignSelection;
    g_cachedCampaignOffset = Setting_CampaignOffset;
    g_cacheCreatedAt = Time::Now;
    g_cacheValid = true;
}

bool ReadRanking(Json::Value@ zone, int &out position, int &out totalPlayers)
{
    position = 0;
    totalPlayers = 0;
    auto ranking = zone.HasKey("ranking") ? zone["ranking"] : Json::Value();
    Json::Value total = ranking.GetType() == Json::Type::Object && ranking.HasKey(TotalPlayersField)
        ? ranking[TotalPlayersField]
        : Json::Value();
    if (total.GetType() != Json::Type::Number || int(total) <= 0)
        return false;
    totalPlayers = total;

    if (ranking.GetType() == Json::Type::Object && ranking.HasKey("position") &&
        ranking["position"].GetType() == Json::Type::Number)
    {
        position = ranking["position"];
        if (position <= 0 || position > totalPlayers)
            return false;
    }
    else
    {
        position = totalPlayers + 1;
    }
    return true;
}

bool IsWorse(int pos, int total, const WorstCandidate &in candidate)
{
    if (Setting_RankingMode == RankingMode::Absolute)
        return pos > candidate.position;
    return int64(pos) * candidate.totalPlayers > int64(candidate.position) * total;
}

void ConsiderCandidate(const string &in campaign, const string &in mapUid, const string &in zone, int pos, int total)
{
    g_scanned++;
    uint insertAt = g_worstMaps.Length;
        for (uint i = 0; i < g_worstMaps.Length; i++)
    {
        if (IsWorse(pos, total, g_worstMaps[i]))
        {
            insertAt = i;
            break;
        }
    }
    if (insertAt >= MaxCachedMaps)
        return;

    WorstCandidate@ candidate = WorstCandidate();
    candidate.campaign = campaign;
    candidate.mapUid = mapUid;
    candidate.zone = zone;
    candidate.position = pos;
    candidate.totalPlayers = total;
    g_worstMaps.InsertAt(insertAt, candidate);
    if (g_worstMaps.Length > MaxCachedMaps)
        g_worstMaps.RemoveLast();
}

int SelectedZoneIndex(uint zoneCount)
{
    int index = 0;
    switch (Setting_Region)
    {
        case Regions::Global:
            index = 0;
            break;
        case Regions::Continental:
            index = 1;
            break;
        case Regions::Local:
            index = 2;
            break;
        case Regions::County:
            index = int(zoneCount) - 1;
            break;
    }
    return index < int(zoneCount) ? index : -1;
}

void ReportWorstMaps()
{
    if (g_worstMaps.Length == 0)
    {
        if (g_scanned > 0 && CacheIsFresh())
        {
            warn("All cached worst maps have been played. New rankings can be fetched after the cache expires.");
            return;
        }
        warn("No map could be evaluated (scanned: " + Text::Format("%d", g_scanned) + ").");
        return;
    }
    for (uint i = 0; i < g_worstMaps.Length; i++)
    {
        auto candidate = g_worstMaps[i];
        print(
            "WORST MAP #" + Text::Format("%d", i + 1) + ": " +
            candidate.campaign + " | " + candidate.mapUid + " | " + candidate.zone +
            " | rank " + Text::Format("%d", candidate.position) + " / " +
            Text::Format("%d", candidate.totalPlayers)
        );
    }
    startnew(PlayWorstMap);
}

void PlayWorstMap()
{
    if (g_worstMaps.Length == 0)
        return;
    string mapUid = g_worstMaps[0].mapUid;

    while (!NadeoServices::IsAuthenticated(CoreAudience)) yield();
    auto req = NadeoServices::Get(
        CoreAudience,
        NadeoServices::BaseURLCore() + "/maps/?mapUidList=" + mapUid
    );
    req.Start();
    while (!req.Finished()) yield();
    if (req.ResponseCode() != 200)
    {
        warn("Could not look up map " + mapUid + ": HTTP " + Text::Format("%d", req.ResponseCode()));
        return;
    }
    auto maps = Json::Parse(req.String());
    if (maps.GetType() != Json::Type::Array || maps.Length == 0)
    {
        warn("Map not found: " + mapUid);
        return;
    }
    string fileUrl = maps[0]["fileUrl"];

    auto app = cast<CTrackMania>(GetApp());
    if (app.RootMap !is null)
    {
        app.BackToMainMenu();
        while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
    }
    print("Loading map " + mapUid);
    app.ManiaTitleControlScriptAPI.PlayMap(fileUrl, "TrackMania/TM_PlayMap_Local", "");
}

void PopPlayedMap(const string &in mapUid)
{
    if (mapUid.Length == 0)
        return;
    for (int i = int(g_worstMaps.Length) - 1; i >= 0; i--)
    {
        if (g_worstMaps[i].mapUid == mapUid)
        {
            print("Played map removed from cached worst maps: " + mapUid);
            g_worstMaps.RemoveAt(i);
        }
    }
}

void CompleteScan()
{
    if (!g_scanFailed)
    {
        SaveCacheSettings();
        PopPlayedMap(g_lastObservedMapUid);
        ReportWorstMaps();
    }
    g_fetching = false;
}
