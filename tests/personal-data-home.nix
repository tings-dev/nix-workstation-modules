# Fictional accounts exercise every provider; never activate or synchronize these.
{ workstation, ... }:
{
  imports = [ workstation.homeModules.personal-data ];
  workstation.personalData = {
    realName = "Fixture User";
    astroid.enable = true;
    accounts = {
      fastmail = {
        provider = "fastmail";
        address = "fixture@example.test";
        aliases = [ "alias@example.test" ];
        primary = true;
        mail.enable = true;
        calendar = {
          enable = true;
          primaryCollection = "Personal";
        };
        contacts.enable = true;
      };
      google = {
        provider = "google";
        address = "fixture-google@example.test";
        mail.enable = true;
      };
      posteo = {
        provider = "posteo";
        address = "fixture-posteo@example.test";
        mail.enable = true;
      };
      nextcloud = {
        provider = "nextcloud";
        address = "fixture-cloud@example.test";
        dav = {
          url = "https://cloud.example.test/remote.php/dav/";
          userName = "fixture";
        };
        calendar = {
          enable = true;
          itemTypes = [
            "VEVENT"
            "VTODO"
          ];
        };
        contacts.enable = true;
      };
    };
    codexResetCalendar = {
      enable = true;
      account = "fastmail";
      calendar = "Personal";
    };
  };
}
