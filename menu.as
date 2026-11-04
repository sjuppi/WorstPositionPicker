void RenderMenu()
{
    if (UI::MenuItem("Get worst 10 campaign maps"))
    {
        startnew(CoroutineFunc(FetchCampaignMapRankings));
    }
}