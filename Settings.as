enum Regions
{
    Local,
    Continental,
    County,
    Global
}

enum RankingMode
{
    Percentage,
    Absolute
}

enum CampaignSelection
{
    AllCampaigns,
    CurrentCampaign,
    SelectedCampaign
}

[Setting category="Region" name="Select region"]
Regions Setting_Region = Regions::Local;

[Setting category="Campaign" name="Campaign selection"]
CampaignSelection Setting_CampaignSelection = CampaignSelection::CurrentCampaign;

[Setting category="Campaign" name="Campaign offset" description="0 is the current campaign; 1 is the previous campaign." if="Setting_CampaignSelection SelectedCampaign"]
int Setting_CampaignOffset = 0;

[Setting category="Ranking" name="Ranking mode" description="Percentage compares position / total players; Absolute compares positions. Unranked counts as total players + 1."]
RankingMode Setting_RankingMode = RankingMode::Percentage;
