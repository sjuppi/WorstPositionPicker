const string LiveAudience = "NadeoLiveServices";
const string CoreAudience = "NadeoServices";
const uint CampaignPageSize = 50;
const uint MapRecordBatchSize = 50;

const int WorstPossibleScore = 2147483647;

int FetchZoneTotal(const string &in mapUid, const string &in zoneId)
{
    auto req = NadeoServices::Get(
        LiveAudience,
        NadeoServices::BaseURLLive() + "/api/token/leaderboard/group/Personal_Best/map/" + mapUid +
            "/surround/1/1?onlyWorld=false&score=" + Text::Format("%d", WorstPossibleScore)
    );
    req.Start();
    while (!req.Finished()) yield();
    if (req.ResponseCode() != 200)
    {
        warn("Surround request failed for " + mapUid + ": HTTP " + Text::Format("%d", req.ResponseCode()));
        return 0;
    }
    trace("Surround response for " + mapUid + ": " + req.String());

    auto response = Json::Parse(req.String());
    if (response.GetType() != Json::Type::Object || !response.HasKey("tops"))
        return 0;
    auto tops = response["tops"];
    for (uint i = 0; i < tops.Length; i++)
    {
        if (string(tops[i]["zoneId"]) != zoneId)
            continue;
        auto entries = tops[i]["top"];
        int highest = 0;
        for (uint j = 0; j < entries.Length; j++)
            highest = Math::Max(highest, int(entries[j]["position"]));
        return highest + 1;
    }
    return 0;
}

void FetchMapRecords(const string &in campaignName, array<string> &in mapUids)
{
    string body = '{"maps":[';
    for (uint i = 0; i < mapUids.Length; i++)
    {
        if (i > 0) body += ",";
        body += '{"mapUid":"' + mapUids[i] + '","groupUid":"Personal_Best"}';
    }
    body += "]}";

    auto req = NadeoServices::Post(
        LiveAudience,
        NadeoServices::BaseURLLive() + "/api/token/leaderboard/group/map",
        body
    );
    req.Start();
    while (!req.Finished()) yield();
    if (req.ResponseCode() != 200)
    {
        warn("Could not fetch map records for " + campaignName + ": HTTP " +
            Text::Format("%d", req.ResponseCode()));
        g_scanFailed = true;
        return;
    }

    auto records = Json::Parse(req.String());
    if (records.GetType() != Json::Type::Array)
    {
        warn("Unexpected map-record response for " + campaignName);
        g_scanFailed = true;
        return;
    }

    for (uint i = 0; i < records.Length; i++)
    {
        auto zones = records[i]["zones"];
        string mapUid = records[i]["mapUid"];
        if (zones.GetType() != Json::Type::Array || zones.Length == 0)
        {
            print(campaignName + " | " + mapUid + " | no ranking returned");
            continue;
        }

        int zoneIndex = SelectedZoneIndex(zones.Length);
        if (zoneIndex < 0)
        {
            print(campaignName + " | " + mapUid + " | selected region is unavailable");
            continue;
        }

        auto zone = zones[zoneIndex];
        string zoneName = zone["zoneName"];
        int position = 0;
        int totalPlayers = 0;
        if (!ReadRanking(zone, position, totalPlayers))
        {
            // The batch endpoint reports length 0, so ask a surround query with an unbeatable score
            auto ranking = zone["ranking"];
            if (ranking.GetType() == Json::Type::Object && ranking.HasKey("position"))
            {
                position = ranking["position"];
                string zoneId = zone["zoneId"];
                totalPlayers = FetchZoneTotal(mapUid, zoneId);
            }
        }
        if (position <= 0 || totalPlayers <= 0 || position > totalPlayers)
        {
            warn(campaignName + " | " + mapUid + " | skipped: ranking or total entry count missing/invalid (field '" + TotalPlayersField + "')");
            g_scanFailed = true;
            continue;
        }

        print(
            campaignName + " | " + mapUid + " | " + zoneName + " | rank " +
            Text::Format("%d", position) + " / " + Text::Format("%d", totalPlayers)
        );
        ConsiderCandidate(campaignName, mapUid, zoneName, position, totalPlayers);
    }
}

void FetchCampaignMapRankings()
{
    if (g_fetching)
        return;
    if (CacheIsFresh() && g_worstMaps.Length > 0)
    {
        ReportWorstMaps();
        return;
    }
    if (!NadeoServices::IsAuthenticated(LiveAudience))
    {
        warn("Nadeo Live Services is not authenticated yet.");
        return;
    }
    if (Setting_CampaignSelection == CampaignSelection::SelectedCampaign && Setting_CampaignOffset < 0)
    {
        warn("Campaign offset must be zero or greater.");
        return;
    }

    g_fetching = true;
    g_cacheValid = false;
    g_worstMaps.RemoveRange(0, g_worstMaps.Length);
    g_scanned = 0;
    g_scanFailed = false;
    uint offset = Setting_CampaignSelection == CampaignSelection::SelectedCampaign
        ? uint(Setting_CampaignOffset)
        : 0;
    uint campaignCount = Setting_CampaignSelection == CampaignSelection::AllCampaigns
        ? CampaignPageSize
        : 1;

    while (true)
    {
        auto req = NadeoServices::Get(
            LiveAudience,
            NadeoServices::BaseURLLive() + "/api/campaign/official" +
                        "?offset=" + Text::Format("%d", offset) +
                        "&length=" + Text::Format("%d", campaignCount)
        );
        req.Start();
        while (!req.Finished()) yield();
        if (req.ResponseCode() != 200)
        {
            warn("Could not fetch campaigns: HTTP " + Text::Format("%d", req.ResponseCode()));
            g_fetching = false;
            return;
        }

        auto response = Json::Parse(req.String());
        auto campaigns = response["campaignList"];
        if (campaigns.GetType() != Json::Type::Array)
        {
            warn("Unexpected campaign response from Nadeo Live Services.");
            g_fetching = false;
            return;
        }
        if (campaigns.Length == 0)
        {
            if (offset == 0 || Setting_CampaignSelection != CampaignSelection::AllCampaigns)
                warn("No campaign was returned for the selected campaign offset.");
            else CompleteScan();
            if (Setting_CampaignSelection != CampaignSelection::AllCampaigns || offset == 0)
                g_fetching = false;
            return;
        }

        uint totalCampaigns = response["itemCount"];
        for (uint campaignIndex = 0; campaignIndex < campaigns.Length; campaignIndex++)
        {
            auto campaign = campaigns[campaignIndex];
            string campaignName = campaign["name"];
            auto playlist = campaign["playlist"];
            if (playlist.GetType() != Json::Type::Array)
            {
                warn("Campaign has no valid map list: " + campaignName);
                g_scanFailed = true;
                continue;
            }

            for (uint batchStart = 0; batchStart < playlist.Length; batchStart += MapRecordBatchSize)
            {
                array<string> mapBatch;
                uint batchEnd = batchStart + MapRecordBatchSize;
                if (batchEnd > playlist.Length)
                    batchEnd = playlist.Length;
                for (uint mapIndex = batchStart; mapIndex < batchEnd; mapIndex++)
                {
                    string mapUid = playlist[mapIndex]["mapUid"];
                    mapBatch.InsertLast(mapUid);
                }
                FetchMapRecords(campaignName, mapBatch);
            }
        }

        if (Setting_CampaignSelection != CampaignSelection::AllCampaigns)
        {
            CompleteScan();
            return;
        }

        offset += campaigns.Length;
        if (offset >= totalCampaigns)
        {
            CompleteScan();
            return;
        }
    }
}
