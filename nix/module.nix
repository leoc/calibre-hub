{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.calibre-hub;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;

  calibre = config.services.calibre-server.package;
  userDb = "/var/lib/calibre-server/users.sqlite";

  # calibre-server users: the hub's service user plus extraUsers (scripts)
  calibreUsers = { ${cfg.calibre.serviceUser} = cfg.calibre.servicePasswordFile; } // cfg.calibre.extraUsers;
  # LoadCredential ids, so the secret files can stay root-owned
  credId = name: "user-${name}";
  tokenCred = i: "api-token-${toString i}";

  columnLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (label: c: "${label}|${c.name}|${c.type}") cfg.customColumns
  );
  hierarchical = cfg.hierarchicalCategories ++ lib.mapAttrsToList (label: _: "#${label}") (
    lib.filterAttrs (_: c: c.hierarchical) cfg.customColumns
  );

  leseliste = pkgs.writeShellScript "calibre-hub-leseliste" ''
    export LESELISTE_TARGET=${lib.escapeShellArg (toString cfg.leseliste.target)}
    export LESELISTE_FORMATS=${lib.escapeShellArg (lib.concatStringsSep "," cfg.leseliste.formats)}
    exec ${lib.getExe cfg.package} handler leseliste
  '';
  handlers = cfg.handlers // lib.optionalAttrs cfg.leseliste.enable { "50-leseliste" = leseliste; };
  handlersDir = pkgs.linkFarm "calibre-hub-handlers" (
    lib.mapAttrsToList (name: path: { inherit name path; }) handlers
  );
  writable = lib.optional (cfg.inbox.path != null) (toString cfg.inbox.path)
    ++ lib.optional cfg.leseliste.enable (toString cfg.leseliste.target);

  column = types.submodule (
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Display name of the column.";
        };
        type = mkOption {
          type = types.enum [
            "text"
            "comments"
            "series"
            "enumeration"
            "datetime"
            "float"
            "int"
            "rating"
            "bool"
          ];
          default = "text";
          description = "calibre column type.";
        };
        hierarchical = mkOption {
          type = types.bool;
          default = false;
          description = "Show dotted values (A.B.C) as a tree in calibre and the hub.";
        };
      };
    }
  );
in
{
  options.services.calibre-hub = {
    enable = mkEnableOption "calibre-hub, an API and web UI on top of calibre-server";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "calibre-hub package.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address the hub listens on (put a TLS proxy in front).";
    };

    port = mkOption {
      type = types.port;
      default = 8084;
    };

    library = mkOption {
      type = types.path;
      description = "Path of the calibre library.";
    };

    group = mkOption {
      type = types.str;
      default = "calibre-hub";
      description = ''
        Group of the hub and calibre-server. The hub needs read access to the
        library's metadata.db to notice changes.
      '';
    };

    customColumns = mkOption {
      type = types.attrsOf column;
      default = { };
      example = {
        kategorie = {
          name = "Kategorie";
          hierarchical = true;
        };
      };
      description = "Custom columns created in the library and included in the API.";
    };

    categoryColumn = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "kategorie";
      description = "Custom column served as category tree (/api/categories, ?kategorie=).";
    };

    hierarchicalCategories = mkOption {
      type = types.listOf types.str;
      default = [ "tags" ];
      description = "Built-in categories shown as a tree in calibre.";
    };

    login = {
      user = mkOption {
        type = types.str;
        default = "arthur";
      };
      passwordFile = mkOption {
        type = types.path;
        description = "Password of the login user (plain text).";
      };
    };

    sessionKeyFile = mkOption {
      type = types.path;
      description = "Secret used to sign session cookies (at least 32 random bytes).";
    };

    apiTokenFiles = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [ "/run/secrets/calibre-hub-token-laptop" ];
      description = ''
        Files with one API token each (at least 16 characters, e.g.
        `openssl rand -hex 32`). The CLI sends it as `Authorization: Bearer`;
        a token has the rights of the login user. Passed as systemd credentials.
      '';
    };

    sessionDays = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Session lifetime; every request extends it.";
    };

    scanInterval = mkOption {
      type = types.ints.positive;
      default = 900;
      description = "Seconds between reconciles when the trigger changelog is missing.";
    };

    reconcileAt = mkOption {
      type = types.strMatching "[0-9]{2}:[0-9]{2}";
      default = "03:30";
      description = "Local time of the daily full reconcile.";
    };

    handlers = mkOption {
      type = types.attrsOf types.path;
      default = { };
      example = lib.literalExpression ''{ "20-notify" = pkgs.writeShellScript "notify" "jq .type"; }'';
      description = ''
        Executables called for every event, in name order, with the event as
        JSON on stdin (type, bookId, changes, book). Exit 0 means done; other
        exit codes are retried with backoff and parked after handlerAttempts.
        The environment has the CALIBRE_HUB_* settings of the service.
      '';
    };

    handlerAttempts = mkOption {
      type = types.ints.positive;
      default = 10;
    };

    handlerTimeout = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "Seconds before a handler run is killed and counted as failed.";
    };

    alertCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/current-system/sw/bin/dmt-alert";
      description = "Executable called with subject and text when a handler is parked.";
    };

    inbox = {
      path = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Folder whose files are imported. Subfolders become the category
          (A/B -> "A.B") and tags (A, B); tags embedded in the files are dropped.
        '';
      };
      stableSeconds = mkOption {
        type = types.ints.positive;
        default = 120;
        description = "A file is imported once it has not changed for this long.";
      };
    };

    fastTags = mkOption {
      type = types.listOf types.str;
      default = [ "leseliste" ];
      description = "Deprecated: the web app saves to reading lists now; still sent in GET /api/config for older web apps.";
    };

    frontend.package = mkOption {
      type = types.nullOr types.package;
      default =
        if builtins.pathExists ../frontend/package.nix then pkgs.callPackage ../frontend/package.nix { } else null;
      defaultText = lib.literalExpression "pkgs.callPackage ../frontend/package.nix { }";
      description = "Built web app (contents of Vite's dist/), served without login; null serves none.";
    };

    classify = {
      enable = mkEnableOption ''
        category suggestions from a local model through the Ollama API. Only
        categories of the existing tree (categoryColumn) are suggested; sure
        ones are applied with the tag `auto-kategorie`, the rest wait for review
      '';
      endpoint = mkOption {
        type = types.str;
        default = "http://127.0.0.1:11434";
        description = "Ollama API the hub sends title, authors, tags and description to; keep it in the home network.";
      };
      model = mkOption {
        type = types.str;
        default = "qwen2.5:3b";
        description = "Model name as Ollama knows it (`ollama pull <model>`).";
      };
      autoApplyThreshold = mkOption {
        type = types.numbers.between 0 1;
        default = 0.85;
        description = "Suggestions at least this confident are applied to books without a category.";
      };
      schedule = mkOption {
        type = types.nullOr (types.strMatching "[0-9]{2}:[0-9]{2}");
        default = "03:45";
        description = "Local time of the nightly run over the books without a category; null for none.";
      };
      timeout = mkOption {
        type = types.ints.positive;
        default = 300;
        description = "Seconds to wait for one answer (a small model on CPU, loading included).";
      };
    };

    metadata = {
      enable = mkEnableOption ''
        metadata cleanup: titles and authors broken by file names are fixed,
        missing ISBN, publisher, date, language, description, series and
        cover are filled from the book file, Hardcover (English books, with
        a token), the DNB (German books) and Open Library, and author
        spellings are unified. Every changed book gets the tag
        `auto-metadaten`; each change is logged and can be reverted
      '';
      sources = mkOption {
        type = types.listOf (
          types.enum [
            "file"
            "hardcover"
            "dnb"
            "openlibrary"
          ]
        );
        default = [
          "file"
          "hardcover"
          "dnb"
          "openlibrary"
        ];
        description = ''
          Sources asked; the book file is always read first when listed.
          Which source wins a field is fixed per field (see the README);
          hardcover is skipped without hardcoverTokenFile.
        '';
      };
      hardcoverTokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/hardcover-token";
        description = ''
          File with the Hardcover API token (https://hardcover.app/account/api,
          with or without "Bearer "). Passed as a systemd credential. null:
          the source hardcover is skipped. A rejected token pauses the
          source and calls alertCommand once a day, as does a token (JWT)
          expiring within 14 days.
        '';
      };
      hardcoverUrl = mkOption {
        type = types.str;
        default = "https://api.hardcover.app/v1/graphql";
        description = "GraphQL endpoint of Hardcover.";
      };
      nightly = mkOption {
        type = types.nullOr (types.strMatching "[0-9]{2}:[0-9]{2}");
        default = null;
        example = "03:15";
        description = "Local time of a nightly run over the incomplete books (plus author unification); null for none.";
      };
      useModel = mkOption {
        type = types.bool;
        default = cfg.classify.enable;
        defaultText = lib.literalExpression "config.services.calibre-hub.classify.enable";
        description = ''
          Ask the classify model (classify.endpoint, classify.model) to clean
          up title and author when the rules can't tell them apart. Only
          title and authors are sent.
        '';
      };
      openLibraryUrl = mkOption {
        type = types.str;
        default = "https://openlibrary.org";
      };
      openLibraryCoversUrl = mkOption {
        type = types.str;
        default = "https://covers.openlibrary.org";
      };
      dnbUrl = mkOption {
        type = types.str;
        default = "https://services.dnb.de/sru/dnb";
        description = "SRU endpoint of the Deutsche Nationalbibliothek.";
      };
      requestInterval = mkOption {
        type = types.ints.unsigned;
        default = 1000;
        description = "Milliseconds between two requests to the same source.";
      };
    };

    leseliste = {
      enable = mkEnableOption "the reading list handler (mirror the synced lists into a folder, one subfolder per list)";
      tag = mkOption {
        type = types.str;
        default = "leseliste";
        description = ''
          Tag of the reading list before lists existed. Its books become the
          list "Leseliste" (synced, default list) once; the tag stays on the
          books but is no longer read afterwards.
        '';
      };
      target = mkOption {
        type = types.path;
        description = "Folder to mirror into, e.g. a Syncthing folder.";
      };
      formats = mkOption {
        type = types.listOf types.str;
        default = [
          "epub"
          "pdf"
        ];
        description = "Formats in order of preference; missing ones are converted to the first.";
      };
    };

    calibre = {
      manage = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Configure calibre-server for the library: localhost only, Basic auth,
          library, columns and users prepared before every start.
        '';
      };
      port = mkOption {
        type = types.port;
        default = 8083;
      };
      triggersPackage = mkOption {
        type = types.package;
        default = pkgs.callPackage ./triggers.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./triggers.nix { }";
        description = ''
          Installer of the changelog triggers, run in calibre-server's preStart.
          A package of its own, so calibre-server only restarts when the
          triggers change, not with every hub update.
        '';
      };
      serviceUser = mkOption {
        type = types.str;
        default = "calibre-hub";
        description = "calibre-server user the hub uses.";
      };
      servicePasswordFile = mkOption {
        type = types.path;
        description = "Password of the service user in calibre-server.";
      };
      extraUsers = mkOption {
        type = types.attrsOf types.path;
        default = { };
        example = lib.literalExpression ''{ arthur = "/run/secrets/calibre-password-arthur"; }'';
        description = "Further calibre-server users (name -> password file), e.g. for calibredb scripts.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.classify.enable -> cfg.categoryColumn != null;
        message = "services.calibre-hub.classify needs services.calibre-hub.categoryColumn.";
      }
    ];

    users.users.calibre-hub = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = { };

    services.calibre-server = mkIf cfg.calibre.manage {
      enable = true;
      libraries = [ cfg.library ];
      host = "127.0.0.1";
      port = cfg.calibre.port;
      group = cfg.group;
      auth = {
        enable = true;
        # the hub talks Basic over localhost; digest would be "auto" without TLS
        mode = "basic";
        inherit userDb;
      };
    };

    systemd.services.calibre-server = mkIf cfg.calibre.manage {
      path = [
        calibre
        pkgs.gnugrep
        pkgs.gnused
      ];
      environment = {
        QT_QPA_PLATFORM = "offscreen";
        LIBRARY = toString cfg.library;
        USERDB = userDb;
        COLUMNS = columnLines;
        HIERARCHICAL = lib.concatStringsSep " " hierarchical;
      };
      unitConfig.RequiresMountsFor = [ (toString cfg.library) ];
      serviceConfig = {
        StateDirectory = "calibre-server";
        LoadCredential = lib.mapAttrsToList (name: file: "${credId name}:${file}") calibreUsers;
      };
      # credentials are only known at runtime, so USERS is built here
      preStart = ''
        USERS=${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: "${name}|${credId name}") calibreUsers))}
        USERS=$(sed "s#|#|$CREDENTIALS_DIRECTORY/#" <<<"$USERS")
        export USERS
        ${pkgs.bash}/bin/bash ${./init.sh}
        # change log for the hub; calibre-server is not running yet. Not
        # cfg.package: a hub update alone must not restart calibre-server.
        ${lib.getExe cfg.calibre.triggersPackage} ${lib.escapeShellArg "${toString cfg.library}/metadata.db"}
      '';
    };

    systemd.services.calibre-hub = {
      description = "calibre-hub API and change detection";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "calibre-server.service"
      ]
      # a model on the same host is up before the first run
      ++ lib.optional ((cfg.classify.enable || cfg.metadata.useModel) && config.services.ollama.enable) "ollama.service";
      wants = [ "calibre-server.service" ];
      unitConfig.RequiresMountsFor = [ (toString cfg.library) ] ++ writable;
      # ebook-convert for the reading list, pdfinfo/pdftotext for metadata
      path = [
        calibre
        pkgs.poppler-utils
      ];
      environment = {
        HOME = "/var/lib/calibre-hub";
        QT_QPA_PLATFORM = "offscreen";
        CALIBRE_HUB_CALIBRE_URL = "http://127.0.0.1:${toString cfg.calibre.port}";
        CALIBRE_HUB_CALIBRE_USER = cfg.calibre.serviceUser;
        CALIBRE_HUB_CALIBRE_PASSWORD_FILE = "%d/calibre-password";
        CALIBRE_HUB_LIBRARY_ID = baseNameOf (toString cfg.library);
        CALIBRE_HUB_CUSTOM_COLUMNS = lib.concatStringsSep "," (lib.attrNames cfg.customColumns);
        CALIBRE_HUB_CATEGORY_COLUMN = lib.optionalString (cfg.categoryColumn != null) cfg.categoryColumn;
        CALIBRE_HUB_STATE_DB = "/var/lib/calibre-hub/state.sqlite";
        CALIBRE_HUB_HOST = cfg.host;
        CALIBRE_HUB_PORT = toString cfg.port;
        CALIBRE_HUB_LIBRARY = toString cfg.library;
        CALIBRE_HUB_SCAN_INTERVAL = toString cfg.scanInterval;
        CALIBRE_HUB_RECONCILE_AT = cfg.reconcileAt;
        CALIBRE_HUB_HANDLERS_DIR = "${handlersDir}";
        CALIBRE_HUB_HANDLER_ATTEMPTS = toString cfg.handlerAttempts;
        CALIBRE_HUB_HANDLER_TIMEOUT = toString cfg.handlerTimeout;
        CALIBRE_HUB_ALERT_COMMAND = lib.optionalString (cfg.alertCommand != null) cfg.alertCommand;
        CALIBRE_HUB_INBOX = lib.optionalString (cfg.inbox.path != null) (toString cfg.inbox.path);
        CALIBRE_HUB_INBOX_STABLE = toString cfg.inbox.stableSeconds;
        CALIBRE_HUB_FAST_TAGS = lib.concatStringsSep "," cfg.fastTags;
        CALIBRE_HUB_LIST_MIGRATE_TAG = cfg.leseliste.tag;
        CALIBRE_HUB_CLASSIFY = lib.boolToString cfg.classify.enable;
        CALIBRE_HUB_CLASSIFY_ENDPOINT = cfg.classify.endpoint;
        CALIBRE_HUB_CLASSIFY_MODEL = cfg.classify.model;
        CALIBRE_HUB_CLASSIFY_THRESHOLD = toString cfg.classify.autoApplyThreshold;
        CALIBRE_HUB_CLASSIFY_SCHEDULE = lib.optionalString (cfg.classify.schedule != null) cfg.classify.schedule;
        CALIBRE_HUB_CLASSIFY_TIMEOUT = toString cfg.classify.timeout;
        CALIBRE_HUB_METADATA = lib.boolToString cfg.metadata.enable;
        CALIBRE_HUB_METADATA_SOURCES = lib.concatStringsSep "," cfg.metadata.sources;
        CALIBRE_HUB_METADATA_NIGHTLY = lib.optionalString (cfg.metadata.nightly != null) cfg.metadata.nightly;
        CALIBRE_HUB_METADATA_MODEL = lib.boolToString cfg.metadata.useModel;
        CALIBRE_HUB_METADATA_INTERVAL = toString cfg.metadata.requestInterval;
        CALIBRE_HUB_OPENLIBRARY_URL = cfg.metadata.openLibraryUrl;
        CALIBRE_HUB_OPENLIBRARY_COVERS_URL = cfg.metadata.openLibraryCoversUrl;
        CALIBRE_HUB_DNB_URL = cfg.metadata.dnbUrl;
        CALIBRE_HUB_HARDCOVER_URL = cfg.metadata.hardcoverUrl;
        CALIBRE_HUB_HARDCOVER_TOKEN_FILE = lib.optionalString (
          cfg.metadata.hardcoverTokenFile != null
        ) "%d/hardcover-token";
        CALIBRE_HUB_FRONTEND =lib.optionalString (cfg.frontend.package != null) "${cfg.frontend.package}";
        CALIBRE_HUB_LOGIN_USER = cfg.login.user;
        CALIBRE_HUB_LOGIN_PASSWORD_FILE = "%d/login-password";
        CALIBRE_HUB_SESSION_KEY_FILE = "%d/session-key";
        CALIBRE_HUB_SESSION_DAYS = toString cfg.sessionDays;
        CALIBRE_HUB_API_TOKEN_FILES = lib.concatStringsSep "," (
          lib.imap0 (i: _: "%d/${tokenCred i}") cfg.apiTokenFiles
        );
      };
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} serve";
        User = "calibre-hub";
        Group = cfg.group;
        StateDirectory = "calibre-hub";
        LoadCredential = [
          "calibre-password:${cfg.calibre.servicePasswordFile}"
          "login-password:${cfg.login.passwordFile}"
          "session-key:${cfg.sessionKeyFile}"
        ]
        ++ lib.imap0 (i: file: "${tokenCred i}:${file}") cfg.apiTokenFiles
        ++ lib.optional (
          cfg.metadata.hardcoverTokenFile != null
        ) "hardcover-token:${toString cfg.metadata.hardcoverTokenFile}";
        Restart = "on-failure";
        RestartSec = 5;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        # the library only through calibre-server; inbox and reading list are ours
        ReadOnlyPaths = [ (toString cfg.library) ];
        ReadWritePaths = writable;
        # files in the inbox and the reading list stay group-writable for srv
        UMask = "0002";
      };
    };
  };
}
