{ }:

{
  "email-monitoring" = {
    ipAddress = "192.168.83.4";
    tapId = "microvm2";
    mac = "02:00:00:00:00:03";
    vsockCid = 1004;
  };

  nixfiles = {
    ipAddress = "192.168.83.3";
    tapId = "microvm1";
    mac = "02:00:00:00:00:02";
    vsockCid = 1003;
  };

  nixpkgs = {
    ipAddress = "192.168.83.5";
    tapId = "microvm3";
    mac = "02:00:00:00:00:04";
    vsockCid = 1005;
  };
}
