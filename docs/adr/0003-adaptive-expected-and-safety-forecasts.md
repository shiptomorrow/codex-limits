# Adaptive expected and safety forecasts

The straight target path ends at a 3% safety buffer. The forecast gives more weight to recent use and relies on earlier history mainly to estimate variation. On first launch, daily token history from `account/usage/read` provides a starting point. The app then records local percentage samples, which gradually become the primary forecast input. It presents an expected forecast and also calculates a conservative safety forecast. It never assumes that a future break will occur. This approach was chosen over both a simple long-term average and complex behavioural modelling.

The status is `Slow down` when the expected forecast falls below twice the configured buffer. It is `Room to use more` when expected remaining usage exceeds 8%. All other cases are `On track`. A one-percentage-point margin prevents the status from changing on minor fluctuations.
