void Main()
{
    while (true)
    {
        CTrackMania@ app = cast<CTrackMania@>(GetApp());
        string mapUid;
        if (app !is null)
        {
            auto map = app.RootMap;
            if (map !is null)
                mapUid = map.MapInfo.MapUid;
        }

        if (mapUid.Length > 0 && mapUid != g_lastObservedMapUid)
        {
            g_lastObservedMapUid = mapUid;
            PopPlayedMap(mapUid);
        }
        else if (mapUid.Length == 0)
        {
            g_lastObservedMapUid = "";
        }
        sleep(1000);
    }
}