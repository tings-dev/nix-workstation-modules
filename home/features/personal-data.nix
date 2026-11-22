# Local-first personal data. Callers declare provider identities and
# capabilities; this module owns protocol endpoints, replica layout, clients,
# secret lookups and timers.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.workstation.personalData;
  inherit (lib) mkIf mkOption types;

  repoRoot = config.workstation.repositoryPath;
  manifest = "${repoRoot}/secretspec.toml";
  provider = "sops://${repoRoot}/secrets/personal-data.enc.yaml";
  stateRoot = "${config.xdg.stateHome}/personal-data";
  dataRoot = "${config.xdg.dataHome}";

  capability = types.submodule {
    options.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this account provides this kind of personal data";
    };
  };

  accountType = types.submodule {
    options = {
      provider = mkOption {
        type = types.enum [
          "fastmail"
          "google"
          "posteo"
          "nextcloud"
        ];
        description = "Remote provider whose implementation this profile owns";
      };

      address = mkOption {
        type = types.strMatching ".*@.*";
        description = "Primary address and remote login identity";
      };

      aliases = mkOption {
        type = types.listOf (types.strMatching ".*@.*");
        default = [ ];
        description = "Additional selectable sending identities for this mailbox";
      };

      dav = {
        url = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Nextcloud DAV base URL; calendar and contacts share its app password";
        };
        userName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "DAV login when it differs from the account email address";
        };
      };

      primary = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this is the default personal-data account";
      };

      mail = mkOption {
        type = capability;
        default = { };
      };
      calendar = mkOption {
        type = types.submodule {
          options = {
            enable = lib.mkEnableOption "calendar replicas for this account";
            primaryCollection = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Default calendar display name; set on exactly one enabled calendar account, independently of primary mail";
            };
            collections = mkOption {
              type = types.listOf (types.either types.str (types.listOf types.str));
              default = [ "from a" ];
              description = "Remote collection IDs or explicit vdirsyncer collection mappings";
            };
            itemTypes = mkOption {
              type = types.listOf types.str;
              default = [ "VEVENT" ];
              description = "CalDAV components to synchronize; include VTODO for tasks";
            };
            readOnly = mkOption {
              type = types.bool;
              default = false;
              description = "Prevent khal edits, for example to server-generated birthday calendars";
            };
            showInKhal = mkOption {
              type = types.bool;
              default = true;
              description = "Expose event calendars in khal; disable for task-only collections";
            };
          };
        };
        default = { };
      };
      contacts = mkOption {
        type = types.submodule {
          options = {
            enable = lib.mkEnableOption "contact replicas for this account";
            collections = mkOption {
              type = types.listOf (types.either types.str (types.listOf types.str));
              default = [ "from a" ];
              description = "Remote address-book IDs or explicit vdirsyncer collection mappings";
            };
          };
        };
        default = { };
      };
    };
  };

  enabledAccounts = lib.filterAttrs (
    _name: account: account.mail.enable || account.calendar.enable || account.contacts.enable
  ) cfg.accounts;
  mailAccounts = lib.filterAttrs (_name: account: account.mail.enable) enabledAccounts;
  calendarAccounts = lib.filterAttrs (_name: account: account.calendar.enable) enabledAccounts;
  contactAccounts = lib.filterAttrs (_name: account: account.contacts.enable) enabledAccounts;
  primaryAccounts = lib.filterAttrs (_name: account: account.primary) enabledAccounts;
  enabledAccountCapabilities = lib.mapAttrs (_name: account: {
    inherit (account)
      provider
      address
      aliases
      primary
      ;
    mail = account.mail.enable;
    calendar = account.calendar;
    contacts = account.contacts;
    inherit (account) dav;
  }) enabledAccounts;
  enrollmentFingerprint = builtins.hashString "sha256" (builtins.toJSON enabledAccountCapabilities);
  enrollmentMarker = "${stateRoot}/enrolled-${enrollmentFingerprint}";
  mailEnabled = mailAccounts != { };
  calendarEnabled = calendarAccounts != { };
  contactsEnabled = contactAccounts != { };
  pimEnabled = calendarEnabled || contactsEnabled;
  fastmailMailEnabled = lib.any (account: account.provider == "fastmail" && account.mail.enable) (
    lib.attrValues enabledAccounts
  );
  fastmailDavEnabled = lib.any (
    account: account.provider == "fastmail" && (account.calendar.enable || account.contacts.enable)
  ) (lib.attrValues enabledAccounts);
  nextcloudDavEnabled = lib.any (
    account: account.provider == "nextcloud" && (account.calendar.enable || account.contacts.enable)
  ) (lib.attrValues enabledAccounts);
  googleMailEnabled = lib.any (account: account.provider == "google" && account.mail.enable) (
    lib.attrValues enabledAccounts
  );
  posteoMailEnabled = lib.any (account: account.provider == "posteo" && account.mail.enable) (
    lib.attrValues enabledAccounts
  );
  primaryMailAccount =
    if primaryAccounts == { } then "" else lib.head (lib.attrNames primaryAccounts);
  primaryCalendarAccounts = lib.filterAttrs (
    _name: account: account.calendar.primaryCollection != null
  ) calendarAccounts;
  primaryCalendarAccount =
    if primaryCalendarAccounts == { } then "" else lib.head (lib.attrNames primaryCalendarAccounts);
  calendarAccountNames = lib.attrNames calendarAccounts;
  contactAccountNames = lib.attrNames contactAccounts;
  enabledServiceNames =
    lib.optional mailEnabled "personal-data-mail.service"
    ++ lib.optional pimEnabled "personal-data-pim.service";
  enabledTimerNames =
    lib.optional mailEnabled "personal-data-mail.timer"
    ++ lib.optional pimEnabled "personal-data-pim.timer";
  allAddresses = lib.concatLists (
    lib.mapAttrsToList (_name: account: [ account.address ] ++ account.aliases) mailAccounts
  );
  aercAccountsPath = "${config.xdg.configHome}/aerc/accounts.conf";
  aercAccountNames =
    lib.attrNames (lib.filterAttrs (_name: account: account.primary) mailAccounts)
    ++ lib.attrNames (lib.filterAttrs (_name: account: !account.primary) mailAccounts);
  aercAccountSection =
    name:
    let
      account = mailAccounts.${name};
      draftsFolder = if account.provider == "google" then "[Gmail]/Drafts" else "Drafts";
    in
    ''
      [${lib.escape [ "[" "]" ] name}]
      ${
        lib.optionalString (
          account.aliases != [ ]
        ) "aliases = ${lib.concatStringsSep "," account.aliases}\n"
      }default = INBOX
      enable-maildir = true
      from = ${cfg.realName} <${account.address}>
      maildir-account-path = ${name}
      outgoing = msmtpq --read-envelope-from --read-recipients
      postpone = ${draftsFolder}
      source = notmuch://
    '';
  aercAccountsText = ''
    # Generated by Home Manager's workstation.personalData compatibility layer.

    ${lib.concatMapStringsSep "\n" aercAccountSection aercAccountNames}
  '';

  # Home Manager renders the main Astroid identities from accounts.email but
  # does not render aliases. Each alias shares its provider's drafts directory
  # and selects the alias account already generated by the msmtp module.
  astroidAliasAccounts = lib.listToAttrs (
    lib.concatLists (
      lib.mapAttrsToList (
        name: declaredAccount:
        let
          account = config.accounts.email.accounts.${name};
        in
        map (
          address:
          lib.nameValuePair address (
            account.astroid.extraConfig
            // {
              name = account.realName;
              email = address;
              default = "false";
              sendmail = "${lib.getExe config.programs.msmtp.package} --account=${lib.escapeShellArg address} --read-envelope-from --read-recipients";
              save_drafts_to = "${account.maildir.absPath}/${account.folders.drafts}/cur/";
              select_query = "";
            }
          )
        ) declaredAccount.aliases
      ) mailAccounts
    )
  );
  astroidFolderQuery =
    folder:
    lib.concatMapStringsSep " or " (
      name:
      "folder:${builtins.toJSON "${name}/${config.accounts.email.accounts.${name}.folders.${folder}}"}"
    ) (lib.attrNames mailAccounts);

  secretHelper = pkgs.writeShellApplication {
    name = "frkl-personal-data-secret";
    runtimeInputs = [
      pkgs.age
      pkgs.secretspec
      pkgs.sops
    ];
    text = ''
      case "''${1:-}" in
        FASTMAIL_MAIL_PASSWORD|FASTMAIL_DAV_PASSWORD|GOOGLE_MAIL_PASSWORD|POSTEO_MAIL_PASSWORD|NEXTCLOUD_DAV_PASSWORD)
          key="$1"
          ;;
        *)
          echo "unknown personal-data secret" >&2
          exit 2
          ;;
      esac

      exec secretspec get "$key" \
        --file ${lib.escapeShellArg manifest} \
        --profile personal-data \
        --provider ${lib.escapeShellArg provider}
    '';
  };

  secretCommand = name: [
    "${secretHelper}/bin/frkl-personal-data-secret"
    name
  ];

  statusCommand = pkgs.writeShellApplication {
    name = "frkl-personal-data-status";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      marker=${lib.escapeShellArg enrollmentMarker}
      if [[ -f "$marker" ]]; then
        echo "enrollment: complete"
      else
        echo "enrollment: pending — follow docs/init-tasks.md in the configuration checkout"
      fi

      for unit in ${lib.escapeShellArgs enabledServiceNames}; do
        echo
        echo "$unit"
        systemctl --user show "$unit" \
          --property=ActiveState,Result,ExecMainStatus,StateChangeTimestamp \
          --no-pager 2>/dev/null || echo "  not deployed"
      done

      echo
      systemctl --user list-timers \
        ${lib.escapeShellArgs enabledTimerNames} \
        --all --no-pager 2>/dev/null || true
      echo
      echo "logs: journalctl --user -u personal-data-{mail,pim}.service"
    '';
  };

  ensureDirectories = pkgs.writeShellScript "personal-data-directories" ''
    install -d -m 0700 \
      ${lib.escapeShellArg "${dataRoot}/mail"} \
      ${lib.escapeShellArg "${dataRoot}/calendars"} \
      ${lib.escapeShellArg "${dataRoot}/contacts"} \
      ${lib.escapeShellArg stateRoot} \
      ${lib.escapeShellArg "${stateRoot}/vdirsyncer"}
  '';

  mailAccount =
    name: account:
    lib.nameValuePair name {
      inherit (account) address aliases primary;
      realName = cfg.realName;
      flavor =
        if account.provider == "fastmail" then
          "fastmail.com"
        else if account.provider == "google" then
          "gmail.com"
        else
          "posteo.de";
      passwordCommand = secretCommand (
        if account.provider == "fastmail" then
          "FASTMAIL_MAIL_PASSWORD"
        else if account.provider == "google" then
          "GOOGLE_MAIL_PASSWORD"
        else
          "POSTEO_MAIL_PASSWORD"
      );
      folders = {
        inbox = "INBOX";
        # All supported providers file authenticated SMTP submissions server-side. A
        # client-side FCC would make a duplicate on the next synchronization.
        sent = null;
        drafts = if account.provider == "google" then "[Gmail]/Drafts" else "Drafts";
        trash = if account.provider == "google" then "[Gmail]/Trash" else "Trash";
      };
      maildir.path = name;
      mbsync = {
        enable = true;
        create = "maildir";
        remove = "none";
        expunge = if account.provider == "google" then "none" else "both";
        patterns = [ "*" ];
        extraConfig.channel = {
          CopyArrivalDate = true;
          Sync =
            if account.provider == "google" then
              # Gmail remains remote-authoritative in v1: pull new messages
              # and flags, but never push local moves or deletions.
              [
                "Pull"
                "New"
                "Flags"
              ]
            else
              "Full";
        };
      };
      msmtp.enable = true;
      aerc.enable = true;
      notmuch.enable = true;
      astroid = {
        enable = cfg.astroid.enable;
        sendMailCommand = "${lib.getExe config.programs.msmtp.package} --account=${lib.escapeShellArg name} --read-envelope-from --read-recipients";
        extraConfig = {
          # Providers save authenticated SMTP submissions server-side. Override
          # both fields: the Home Manager renderer otherwise interpolates our
          # intentionally null folders.sent into save_sent_to.
          save_sent = "false";
          save_sent_to = "";
          gpgkey = "";
          always_gpg_sign = "false";
        };
      };
    };

  calendarAccount =
    name: account:
    lib.nameValuePair name {
      primary = name == primaryCalendarAccount;
      primaryCollection = account.calendar.primaryCollection;
      local.path = "${dataRoot}/calendars/${name}";
      remote = {
        type = "caldav";
        url = if account.provider == "nextcloud" then account.dav.url else "https://caldav.fastmail.com/";
        userName = if account.dav.userName != null then account.dav.userName else account.address;
        passwordCommand = secretCommand (
          if account.provider == "nextcloud" then "NEXTCLOUD_DAV_PASSWORD" else "FASTMAIL_DAV_PASSWORD"
        );
      };
      vdirsyncer = {
        enable = true;
        # Discovery may create local collections from the provider, never the
        # reverse. A newly created remote collection needs explicit discovery.
        collections = account.calendar.collections;
        itemTypes = account.calendar.itemTypes;
        metadata = [
          "color"
          "displayname"
        ];
      };
      khal = {
        enable = account.calendar.showInKhal;
        readOnly = account.calendar.readOnly;
        type = "discover";
        glob = "*";
        addresses = [ account.address ] ++ account.aliases;
        priority = if name == primaryCalendarAccount then 20 else 10;
      };
    };

  contactAccount =
    name: account:
    lib.nameValuePair name {
      local.path = "${dataRoot}/contacts/${name}";
      remote = {
        type = "carddav";
        url = if account.provider == "nextcloud" then account.dav.url else "https://carddav.fastmail.com/";
        userName = if account.dav.userName != null then account.dav.userName else account.address;
        passwordCommand = secretCommand (
          if account.provider == "nextcloud" then "NEXTCLOUD_DAV_PASSWORD" else "FASTMAIL_DAV_PASSWORD"
        );
      };
      vdirsyncer = {
        enable = true;
        collections = account.contacts.collections;
        metadata = [ "displayname" ];
      };
      khard = {
        enable = true;
        type = "discover";
        glob = "*";
      };
    };

  identities = allAddresses;
  identityRegexp = lib.concatStringsSep "\\|" (map lib.escapeRegex identities);
  elispIdentities = lib.concatMapStringsSep " " (address: ''"${address}"'') identities;
in
{
  imports = [
    ../repository.nix
    ./codex-reset-calendar.nix
  ];

  options.workstation.personalData = {
    realName = mkOption {
      type = types.str;
      description = "Display name shared by the declared mail identities";
    };

    accounts = mkOption {
      type = types.attrsOf accountType;
      default = { };
      description = "Provider identities and the personal-data capabilities each one supplies";
    };

    astroid.enable = lib.mkEnableOption "the Astroid GUI over the existing mail replicas";
  };

  config = {
    assertions = [
      {
        assertion = enabledAccounts != { };
        message = "workstation.personalData requires at least one enabled account capability";
      }
      {
        assertion = !cfg.astroid.enable || mailEnabled;
        message = "personal-data Astroid requires at least one enabled mail account";
      }
      {
        assertion = lib.length (lib.attrNames primaryAccounts) == 1;
        message = "workstation.personalData requires exactly one primary account";
      }
      {
        assertion = lib.all (account: !account.primary || account.mail.enable) (
          lib.attrValues enabledAccounts
        );
        message = "the primary personal-data account must provide mail";
      }
      {
        assertion = !calendarEnabled || lib.length (lib.attrNames primaryCalendarAccounts) == 1;
        message = "exactly one enabled calendar account must set calendar.primaryCollection to its default display name";
      }
      {
        assertion = lib.length allAddresses == lib.length (lib.unique allAddresses);
        message = "personal-data mail addresses and aliases must be globally unique";
      }
      {
        assertion = lib.all (
          account:
          lib.elem account.provider [
            "fastmail"
            "nextcloud"
          ]
          || (!account.calendar.enable && !account.contacts.enable)
        ) (lib.attrValues enabledAccounts);
        message = "calendar and contacts are supported only for Fastmail and Nextcloud";
      }
      {
        assertion = lib.all (
          account:
          account.provider != "nextcloud"
          || (!account.mail.enable && account.dav.url != null && lib.hasPrefix "https://" account.dav.url)
        ) (lib.attrValues enabledAccounts);
        message = "Nextcloud accounts require an HTTPS dav.url and cannot provide mail";
      }
      {
        assertion = !(lib.hasInfix "maildir-store =" config.home.file.${aercAccountsPath}.text);
        message = "personal-data aerc accounts must not use the deprecated maildir-store setting";
      }
      {
        assertion = !(lib.hasInfix "source = notmuch:///" config.home.file.${aercAccountsPath}.text);
        message = "personal-data aerc accounts must discover the notmuch database instead of embedding its path";
      }
    ];

    home.packages = [
      pkgs.age
      pkgs.secretspec
      pkgs.sops
      secretHelper
      statusCommand
    ];

    accounts.email = {
      maildirBasePath = "${dataRoot}/mail";
      accounts = lib.mapAttrs' mailAccount mailAccounts;
    };

    accounts.calendar = {
      basePath = "${dataRoot}/calendars";
      accounts = lib.mapAttrs' calendarAccount calendarAccounts;
    };

    accounts.contact = {
      basePath = "${dataRoot}/contacts";
      accounts = lib.mapAttrs' contactAccount contactAccounts;
    };

    programs = {
      mbsync.enable = true;
      msmtp.enable = true;
      notmuch = {
        enable = true;
        settings = {
          new.tags = [ ];
          maildir.synchronize_flags = true;
        };
      };
      aerc = {
        enable = true;
        extraConfig.general.unsafe-accounts-conf = true;
      };
      astroid = mkIf cfg.astroid.enable {
        enable = true;
        # P requests the same service as the existing timer, so synchronization
        # and enrollment checks retain one owner. Disable automatic GUI polling.
        pollScript = lib.mkDefault "exec ${pkgs.systemd}/bin/systemctl --user start personal-data-mail.service";
        settings = {
          accounts = astroidAliasAccounts;
          poll.interval = lib.mkDefault 0;
          startup.queries = {
            # Override the template's tag:inbox query: our index derives its
            # flags from Maildir and deliberately adds no inbox tag.
            inbox = lib.mkDefault (astroidFolderQuery "inbox");
            "Unread inbox" = lib.mkDefault "(${astroidFolderQuery "inbox"}) and tag:unread";
            Drafts = lib.mkDefault (astroidFolderQuery "drafts");
            Flagged = lib.mkDefault "tag:flagged";
          };
          editor = {
            cmd = lib.mkDefault "${config.programs.emacs.finalPackage}/bin/emacs %1";
            external_editor = lib.mkDefault "true";
            markdown_processor = lib.mkDefault "${pkgs.cmark}/bin/cmark";
          };
          mail.reply.quote_processor = lib.mkDefault "${pkgs.w3m}/bin/w3m -dump -T text/html";
        };
      };
      vdirsyncer = {
        enable = true;
        statusPath = "${stateRoot}/vdirsyncer";
      };
      khal.enable = calendarAccounts != { };
      khard.enable = contactAccounts != { };

      emacs = {
        extraPackages = epkgs: [ epkgs.notmuch ];
        extraConfig = ''
          (require 'notmuch)
          (setq notmuch-identities '(${elispIdentities}))
          (setq notmuch-always-prompt-for-sender t)
          (setq notmuch-fcc-dirs nil)
          (setq message-alternative-emails "${identityRegexp}")
          (setq send-mail-function 'sendmail-send-it)
          (setq message-send-mail-function 'message-send-mail-with-sendmail)
          (setq sendmail-program "${pkgs.msmtp}/bin/msmtp")
          (setq mail-specify-envelope-from t)
          (setq message-sendmail-envelope-from 'header)
          (setq message-sendmail-extra-arguments '("--read-envelope-from" "--read-recipients"))
        '';
      };
    };

    home.activation.personalDataDirectories = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${ensureDirectories}
    '';

    # Home Manager's notmuch account renderer still emits options deprecated by
    # aerc 0.22. Keep using the account module for the other clients, but own
    # this compatibility-sensitive generated file.
    home.file.${aercAccountsPath}.text = lib.mkForce aercAccountsText;

    xdg.configFile."frkl/personal-data.conf".text = ''
      capability_policy_version=1
      manifest=${lib.escapeShellArg manifest}
      provider=${lib.escapeShellArg provider}
      state_root=${lib.escapeShellArg stateRoot}
      data_root=${lib.escapeShellArg dataRoot}
      marker=${lib.escapeShellArg enrollmentMarker}
      primary_calendar_collection=${
        lib.escapeShellArg (
          if primaryCalendarAccount == "" then
            ""
          else
            calendarAccounts.${primaryCalendarAccount}.calendar.primaryCollection
        )
      }
      fastmail_mail_enabled=${lib.boolToString fastmailMailEnabled}
      fastmail_dav_enabled=${lib.boolToString fastmailDavEnabled}
      nextcloud_dav_enabled=${lib.boolToString nextcloudDavEnabled}
      google_mail_enabled=${lib.boolToString googleMailEnabled}
      posteo_mail_enabled=${lib.boolToString posteoMailEnabled}
      mail_enabled=${lib.boolToString mailEnabled}
      calendar_enabled=${lib.boolToString calendarEnabled}
      contacts_enabled=${lib.boolToString contactsEnabled}
      primary_mail_account=${lib.escapeShellArg primaryMailAccount}
      calendar_accounts=${lib.escapeShellArg (lib.concatStringsSep " " calendarAccountNames)}
      contact_accounts=${lib.escapeShellArg (lib.concatStringsSep " " contactAccountNames)}
    '';

    systemd.user = {
      services =
        lib.optionalAttrs mailEnabled {
          personal-data-mail = {
            Unit = {
              Description = "Synchronize personal mail and update the notmuch index";
              Wants = [ "network-online.target" ];
              After = [ "network-online.target" ];
              ConditionPathExists = enrollmentMarker;
            };
            Service = {
              Type = "oneshot";
              UMask = "0077";
              ExecStartPre = "${ensureDirectories}";
              ExecStart = "${pkgs.isync}/bin/mbsync --all";
              ExecStartPost = "${pkgs.notmuch}/bin/notmuch new";
              Environment = [ "NOTMUCH_CONFIG=%h/.config/notmuch/default/config" ];
            };
          };
        }
        // lib.optionalAttrs pimEnabled {
          personal-data-pim = {
            Unit = {
              Description = "Synchronize personal calendars and contacts";
              Wants = [ "network-online.target" ];
              After = [ "network-online.target" ];
              ConditionPathExists = enrollmentMarker;
            };
            Service = {
              Type = "oneshot";
              UMask = "0077";
              ExecStartPre = "${ensureDirectories}";
              ExecStart = "${pkgs.vdirsyncer}/bin/vdirsyncer sync";
            }
            // lib.optionalAttrs calendarEnabled {
              ExecStartPost = lib.escapeShellArgs (
                [
                  "${pkgs.vdirsyncer}/bin/vdirsyncer"
                  "metasync"
                ]
                ++ map (name: "calendar_${name}") calendarAccountNames
              );
            };
          };
        };

      timers =
        lib.optionalAttrs mailEnabled {
          personal-data-mail = {
            Unit.Description = "Synchronize personal mail every five minutes";
            Timer = {
              OnCalendar = "*:0/5";
              Persistent = true;
              RandomizedDelaySec = "1m";
              Unit = "personal-data-mail.service";
            };
            Install.WantedBy = [ "timers.target" ];
          };
        }
        // lib.optionalAttrs pimEnabled {
          personal-data-pim = {
            Unit.Description = "Synchronize personal calendars and contacts every fifteen minutes";
            Timer = {
              OnCalendar = "*:0/15";
              Persistent = true;
              RandomizedDelaySec = "2m";
              Unit = "personal-data-pim.service";
            };
            Install.WantedBy = [ "timers.target" ];
          };
        };
    };
  };
}
