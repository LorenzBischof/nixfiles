{ ... }:
{
  # Roams networks, so the nas can't reliably scrape it: push instead.
  my.monitoring.client = {
    enable = true;
    mode = "push";
  };
}
