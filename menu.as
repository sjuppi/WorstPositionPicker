void RenderMenu()
{
    if (UI::MenuItem("Get worst campaign maps"))
    {
        startnew(CoroutineFunc(FetchCampaignMapRankings));
    }
}