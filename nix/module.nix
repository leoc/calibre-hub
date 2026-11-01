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

  columnLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (label: c: "${label}|${c.name}|${c.type}") cfg.customColumns
  );
  hierarchical = cfg.hierarchicalCategories ++ lib.mapAttrsToList (label: _: "#${label}") (
    lib.filterAttrs (_: c: c.hierarchical) cfg.customColumns
  );

  leseliste = pkgs.writeShellScript "calibre-hub-leseliste" ''
    export LESELISTE_TAG=${lib.escapeShellArg cfg.leseliste.tag}
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
      description = "Tags the web app offers as one-click toggles (GET /api/config).";
    };

    frontend.package = mkOption {
      type = types.nullOr types.package;
      default =
        if builtins.pathExists ../frontend/package.nix then pkgs.callPackage ../frontend/package.nix { } else null;
      defaultText = lib.literalExpression "pkgs.callPackage ../frontend/package.nix { }";
      description = "Built web app (contents of Vite's dist/), served without login; null serves none.";
    };

    leseliste = {
      enable = mkEnableOption "the reading list handler (mirror tagged books into a folder)";
      tag = mkOption {
        type = types.str;
        default = "leseliste";
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
        # change log for the hub; calibre-server is not running yet
        ${lib.getExe cfg.package} install-triggers ${lib.escapeShellArg "${toString cfg.library}/metadata.db"}
      '';
    };

    systemd.services.calibre-hub = {
      description = "calibre-hub API and change detection";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "calibre-server.service"
      ];
      wants = [ "calibre-server.service" ];
      unitConfig.RequiresMountsFor = [ (toString cfg.library) ] ++ writable;
      # ebook-convert for the reading list
      path = [ calibre ];
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
        CALIBRE_HUB_FRONTEND = lib.optionalString (cfg.frontend.package != null) "${cfg.frontend.package}";
        CALIBRE_HUB_LOGIN_USER = cfg.login.user;
        CALIBRE_HUB_LOGIN_PASSWORD_FILE = "%d/login-password";
        CALIBRE_HUB_SESSION_KEY_FILE = "%d/session-key";
        CALIBRE_HUB_SESSION_DAYS = toString cfg.sessionDays;
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
        ];
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
