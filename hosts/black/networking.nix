{
  networking = {
    useDHCP = false;
    interfaces.eth0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "65.109.71.108";
          prefixLength = 26;
        }
      ];
      ipv6.addresses = [
        {
          address = "2a01:4f9:3051:4d41::2";
          prefixLength = 64;
        }
      ];
    };
    defaultGateway = {
      address = "65.109.71.65";
      interface = "eth0";
    };
    defaultGateway6 = {
      address = "fe80::1";
      interface = "eth0";
    };
    nameservers = [
      "1.1.1.1"
      "9.9.9.9"
      "2606:4700:4700::1111"
      "2620:fe::fe"
    ];
  };
}
