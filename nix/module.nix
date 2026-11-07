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
  # hub users besides the login user: credentials and CALIBRE_HUB_USERS
  # ("name:role:passwordFile[:tokenFile|...]")
  hubUserCred = name: "hub-user-${name}";
  hubTokenCred = name: i: "hub-user-${name}-token-${toString i}";
  hubUsersEnv = lib.concatStringsSep "," (
    lib.mapAttrsToList (
      name: u:
      "${name}:${u.role}:%d/${hubUserCred name}"
      + lib.optionalString (u.apiTokenFiles != [ ]) (
        ":" + lib.concatStringsSep "|" (lib.imap0 (i: _: "%d/${hubTokenCred name i}") u.apiTokenFiles)
      )
    ) cfg.users
  );
  hubUsersCreds = lib.concatLists (
    lib.mapAttrsToList (
      name: u:
      [ "${hubUserCred name}:${toString u.passwordFile}" ]
      ++ lib.imap0 (i: file: "${hubTokenCred name i}:${toString file}") u.apiTokenFiles
    ) cfg.users
  );

  columnLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (label: c: "${label}|${c.name}|${c.type}") cfg.customColumns
  );
  hierarchical = cfg.hierarchicalCategories ++ lib.mapAttrsToList (label: _: "#${label}") (
    lib.filterAttrs (_: c: c.hierarchical) cfg.customColumns
  );

  # users with a reader folder of their own: their synced lists go there,
  # not into leseliste.target
  ownTargets = lib.filterAttrs (_: u: u.leseliste.target != null) cfg.users;
  syncUsers = lib.attrNames ownTargets;
  leselisteHandler =
    name: target: env:
    pkgs.writeShellScript name ''
      export LESELISTE_TARGET=${lib.escapeShellArg (toString target)}
      export LESELISTE_FORMATS=${lib.escapeShellArg (lib.concatStringsSep "," cfg.leseliste.formats)}
      ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") env)}
      exec ${lib.getExe cfg.package} handler leseliste
    '';
  leseliste = leselisteHandler "calibre-hub-leseliste" cfg.leseliste.target (
    lib.optionalAttrs (syncUsers != [ ]) { LESELISTE_EXCLUDE_OWNERS = lib.concatStringsSep "," syncUsers; }
  );
  userLeselisten = lib.mapAttrs' (
    name: u:
    lib.nameValuePair "50-leseliste-${name}" (
      leselisteHandler "calibre-hub-leseliste-${name}" u.leseliste.target { LESELISTE_OWNERS = name; }
    )
  ) ownTargets;
  handlers =
    cfg.handlers // lib.optionalAttrs cfg.leseliste.enable ({ "50-leseliste" = leseliste; } // userLeselisten);
  handlersDir = pkgs.linkFarm "calibre-hub-handlers" (
    lib.mapAttrsToList (name: path: { inherit name path; }) handlers
  );
  # a root's parent: the Eingang moves files to <root>-papierkorb next to the
  # root, with one rename, which fails between two mounts of ReadWritePaths.
  # The same goes for the inbox; uploads wait in the state directory, which
  # is writable anyway, and their trash folder lies there too.
  writable = lib.optional (cfg.inbox.path != null) (dirOf (toString cfg.inbox.path))
    ++ map (root: dirOf (toString root)) cfg.backlogImport.roots
    ++ lib.optional cfg.leseliste.enable (toString cfg.leseliste.target)
    ++ lib.optionals cfg.leseliste.enable (lib.mapAttrsToList (_: u: toString u.leseliste.target) ownTargets);

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
      # the server binary only; `hub` (CLI + TUI) is packages.hub
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "calibre-hub.packages.\${system}.server";
      description = "calibre-hub package (the server binary, `calibre-hub`).";
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

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            role = mkOption {
              type = types.enum [
                "admin"
                "reader"
              ];
              default = "reader";
              description = ''
                admin: edit, upload, delete, bulk changes. reader: reads and
                downloads, keeps own lists, reading progress and reader settings.
              '';
            };
            passwordFile = mkOption {
              type = types.path;
              description = "Password of the user (plain text), e.g. a sops secret. Passed as a systemd credential.";
            };
            apiTokenFiles = mkOption {
              type = types.listOf types.path;
              default = [ ];
              description = "API tokens of the user (like `apiTokenFiles`), with the user's rights.";
            };
            leseliste.target = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = "/srv/books/reader-lea";
              description = ''
                A reader folder of the user's own (e.g. a Syncthing folder for
                their e-reader): the user's synced lists are mirrored there
                instead of into `leseliste.target`, and a reader may then sync
                their lists (without one only admins sync). Needs
                `leseliste.enable`.
              '';
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''{ lea = { role = "reader"; passwordFile = "/run/secrets/calibre-hub-lea"; }; }'';
      description = ''
        Further hub users besides the login user (`login.user`, always an
        admin, with the tokens of `apiTokenFiles`). Each has their own
        lists, reading progress and reader settings; the library is shared.
        A user removed here keeps their data but can't log in any more.
      '';
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

    handlerRetryDelay = mkOption {
      type = types.ints.positive;
      default = 10;
      description = "Seconds before a failed handler's second attempt, doubled with every further one.";
    };

    eventInterval = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = ''
        Seconds between two looks for new events of the background work
        (handlers' retries, metadata, classification, conversion, EPUB fixer,
        embedding, lists, private tags). Null: each its own, 2 to 10 seconds.
      '';
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
          Folder whose files go through the Eingang. Subfolders become the
          category (A/B -> "A.B") and tags (A, B); tags embedded in the files
          are dropped. From the threshold of the source Inbox on (90 unless
          changed in the Eingang) a book goes to the library by itself, the
          others wait in the Eingang.

          What the Eingang throws away moves to `<path>-papierkorb` next to
          the folder: the hub's group needs write access to the folder's
          parent, the service may write there.
        '';
      };
      stableSeconds = mkOption {
        type = types.ints.positive;
        default = 120;
        description = "A file is analysed once it has not changed for this long.";
      };
    };

    intake = {
      startDelay = mkOption {
        type = types.ints.positive;
        default = 60;
        description = "Seconds after a start before the Eingang first looks at the import roots.";
      };
      interval = mkOption {
        type = types.ints.positive;
        default = 300;
        description = "Seconds between two looks of the Eingang at the import roots.";
      };
      tick = mkOption {
        type = types.ints.positive;
        default = 30;
        description = "Seconds between two looks of the Eingang at the inbox and the uploads, and at a repair the import roots wait for.";
      };
    };

    backlogImport.unsureTag = mkOption {
      type = types.str;
      default = "auto-unsicher";
      description = ''
        Tag for books whose file name could not be read for sure (which side
        of " - " is the author), after the file, the metadata sources and the
        model were asked: title and authors stay for a manual review.
      '';
    };

    backlogImport.roots = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [ "/srv/media/ebooks/inbox" ];
      description = ''
        Folders the Eingang reads an old collection from: folders never
        become categories or tags, calibre library folders bring their
        metadata.opf and cover.jpg, files that aren't books stay. Empty: none.

        What the Eingang throws away moves to `<root>-papierkorb` next to the
        root, under its path in the root: the hub's group needs write access
        to the root's parent and the root's folders, and the service may
        write in the parent (the library stays read-only).
      '';
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
      retryDelay = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "Seconds before the second attempt at a model that didn't answer, doubled with the third.";
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
          with or without "Bearer "). Passed as a systemd credential; also
          used by hardcoverSync. null: the source hardcover is skipped. A rejected token pauses the
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
      ocrJobs = mkOption {
        type = types.ints.unsigned;
        default = 2;
        description = ''
          Books without a text layer read by OCR at the same time (first and
          last pages, one thread each, low priority), so a big import doesn't
          take the host. 0: no OCR, such a book is decided by its metadata
          and file name.
        '';
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

    hardcoverSync = {
      enable = mkEnableOption ''
        the Hardcover sync, hub -> Hardcover, with the token of
        metadata.hardcoverTokenFile: the books of the library get their
        Hardcover book in the background (read-only, kept in the state DB),
        and the reading progress of `user` becomes the book's status
        ("Currently Reading" with the pages read, "Read" with the date) on
        Hardcover. Only books without a status or with "Want to Read" or
        "Currently Reading" are changed; ratings, reviews and lists are
        never written. Without `write` a dry run that only logs the planned
        writes
      '';
      write = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Send the planned status and progress changes to Hardcover. false:
          dry run, each planned write is logged once per progress change
          ("hardcover sync: dry run: ... would ..."); switched on, they are
          planned again and sent.
        '';
      };
      user = mkOption {
        type = types.str;
        default = cfg.login.user;
        defaultText = lib.literalExpression "config.services.calibre-hub.login.user";
        description = "Hub user whose reading progress is synced (the Hardcover account is the token's).";
      };
      interval = mkOption {
        type = types.ints.positive;
        default = 900;
        description = "Seconds between two sync runs.";
      };
      batch = mkOption {
        type = types.ints.positive;
        default = 100;
        description = "Books looked up on Hardcover per run (up to two requests each, at metadata.requestInterval).";
      };
      readAt = mkOption {
        type = types.numbers.between 0 1;
        default = 0.98;
        description = "Progress from which a book counts as read.";
      };
      privateTags = mkOption {
        type = types.listOf types.str;
        default = [
          "Private"
          "privat"
        ];
        description = ''
          Books with one of these tags (any case) are never sent to Hardcover,
          not even their title or ISBN for matching. Tagged after a sync, what
          the hub added on Hardcover is deleted again, and a user book that was
          there before (e.g. imported) is set private; removing the tag
          restores its privacy and the book syncs again.
        '';
      };
    };

    embed = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Embed metadata and cover into the book files (through calibre-server,
          only formats calibre can write) after an edit of title, authors,
          series, tags, description, identifiers, languages, publisher, date,
          rating or cover, so copies on readers show the same. Changes the
          files' checksums; the KOReader partial MD5 a file had before is kept
          in the state DB (file_checksums).
        '';
      };
      delay = mkOption {
        type = types.ints.positive;
        default = 60;
        description = "Seconds after the last edit of a book before its files are rewritten (several quick edits, one rewrite).";
      };
    };

    convert = {
      enable = mkEnableOption ''
        conversion of added books (inbox, upload, calibre) into the target
        format; the original stays, the converted file is added. The whole
        library can be converted through POST /api/convert either way
      '';
      target = mkOption {
        type = types.enum [
          "EPUB"
          "AZW3"
          "MOBI"
          "PDF"
          "DOCX"
          "FB2"
        ];
        default = "EPUB";
      };
      ignore = mkOption {
        type = types.listOf types.str;
        default = [
          "PDF"
          "CBZ"
          "CBR"
        ];
        description = "Formats never converted from (a book with only these is left alone).";
      };
    };

    duplicates.threshold = mkOption {
      type = types.addCheck types.float (x: x >= 0.5 && x <= 1.0);
      default = 0.85;
      description = ''
        How alike two titles of the same author must be (0.5 to 1; token
        overlap of the main titles) to show as duplicates. A shared ISBN or
        the same file always counts. The Duplikate page can ask with another
        threshold.
      '';
    };

    epubFix = {
      onImport = mkEnableOption ''
        the EPUB fixer for added books (inbox, upload, calibre) and books that
        get an EPUB: mimetype, encodings, a missing or meaningless
        dc:language, the spine's NCX, the cover meta, img tags without a
        source, links to a body id. The library can be checked and repaired
        through POST /api/epub-fix either way
      '';
      keepOriginal = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Keep the EPUB as it was before the first repair as format
          ORIGINAL_EPUB (calibre's name for it, as in Polish books).
        '';
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
      {
        assertion = cfg.hardcoverSync.enable -> cfg.metadata.hardcoverTokenFile != null;
        message = "services.calibre-hub.hardcoverSync needs services.calibre-hub.metadata.hardcoverTokenFile.";
      }
      {
        assertion = !(cfg.users ? ${cfg.login.user});
        message = "services.calibre-hub.users: ${cfg.login.user} is the login user (login.user), configured there.";
      }
      {
        assertion = ownTargets != { } -> cfg.leseliste.enable;
        message = "services.calibre-hub.users.<name>.leseliste.target needs services.calibre-hub.leseliste.enable.";
      }
      {
        assertion = lib.all (n: builtins.match "[A-Za-z0-9._-]+" n != null) (lib.attrNames cfg.users);
        message = "services.calibre-hub.users: names may only contain letters, digits, '.', '_' and '-'.";
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
      unitConfig.RequiresMountsFor = [ (toString cfg.library) ] ++ writable ++ map toString cfg.backlogImport.roots;
      # ebook-convert for the reading list and conversions; the rule flow
      # reads books with pdfinfo/pdftotext/pdftoppm, djvutxt/djvused/ddjvu,
      # ebook-meta/ebook-convert, and scans with tesseract
      path = [
        calibre
        pkgs.poppler-utils
        pkgs.djvulibre
        (pkgs.tesseract.override {
          enableLanguages = [
            "deu"
            "eng"
          ];
        })
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
        CALIBRE_HUB_HANDLER_RETRY_DELAY = toString cfg.handlerRetryDelay;
        CALIBRE_HUB_EVENT_INTERVAL = lib.optionalString (cfg.eventInterval != null) (toString cfg.eventInterval);
        CALIBRE_HUB_ALERT_COMMAND = lib.optionalString (cfg.alertCommand != null) cfg.alertCommand;
        CALIBRE_HUB_INBOX = lib.optionalString (cfg.inbox.path != null) (toString cfg.inbox.path);
        CALIBRE_HUB_INBOX_STABLE = toString cfg.inbox.stableSeconds;
        CALIBRE_HUB_INTAKE_START = toString cfg.intake.startDelay;
        CALIBRE_HUB_INTAKE_INTERVAL = toString cfg.intake.interval;
        CALIBRE_HUB_INTAKE_TICK = toString cfg.intake.tick;
        CALIBRE_HUB_IMPORT_ROOTS = lib.concatMapStringsSep ":" toString cfg.backlogImport.roots;
        CALIBRE_HUB_IMPORT_UNSURE_TAG = cfg.backlogImport.unsureTag;
        CALIBRE_HUB_FAST_TAGS = lib.concatStringsSep "," cfg.fastTags;
        CALIBRE_HUB_LIST_MIGRATE_TAG = cfg.leseliste.tag;
        CALIBRE_HUB_CLASSIFY = lib.boolToString cfg.classify.enable;
        CALIBRE_HUB_CLASSIFY_ENDPOINT = cfg.classify.endpoint;
        CALIBRE_HUB_CLASSIFY_MODEL = cfg.classify.model;
        CALIBRE_HUB_CLASSIFY_THRESHOLD = toString cfg.classify.autoApplyThreshold;
        CALIBRE_HUB_CLASSIFY_SCHEDULE = lib.optionalString (cfg.classify.schedule != null) cfg.classify.schedule;
        CALIBRE_HUB_CLASSIFY_TIMEOUT = toString cfg.classify.timeout;
        CALIBRE_HUB_CLASSIFY_RETRY_DELAY = toString cfg.classify.retryDelay;
        CALIBRE_HUB_METADATA = lib.boolToString cfg.metadata.enable;
        CALIBRE_HUB_METADATA_SOURCES = lib.concatStringsSep "," cfg.metadata.sources;
        CALIBRE_HUB_METADATA_NIGHTLY = lib.optionalString (cfg.metadata.nightly != null) cfg.metadata.nightly;
        CALIBRE_HUB_METADATA_MODEL = lib.boolToString cfg.metadata.useModel;
        CALIBRE_HUB_OCR_JOBS = toString cfg.metadata.ocrJobs;
        CALIBRE_HUB_METADATA_INTERVAL = toString cfg.metadata.requestInterval;
        CALIBRE_HUB_OPENLIBRARY_URL = cfg.metadata.openLibraryUrl;
        CALIBRE_HUB_OPENLIBRARY_COVERS_URL = cfg.metadata.openLibraryCoversUrl;
        CALIBRE_HUB_DNB_URL = cfg.metadata.dnbUrl;
        CALIBRE_HUB_HARDCOVER_URL = cfg.metadata.hardcoverUrl;
        CALIBRE_HUB_HARDCOVER_TOKEN_FILE = lib.optionalString (
          cfg.metadata.hardcoverTokenFile != null
        ) "%d/hardcover-token";
        CALIBRE_HUB_HARDCOVER_SYNC = lib.boolToString cfg.hardcoverSync.enable;
        CALIBRE_HUB_HARDCOVER_SYNC_WRITE = lib.boolToString cfg.hardcoverSync.write;
        CALIBRE_HUB_HARDCOVER_SYNC_USER = cfg.hardcoverSync.user;
        CALIBRE_HUB_HARDCOVER_SYNC_INTERVAL = toString cfg.hardcoverSync.interval;
        CALIBRE_HUB_HARDCOVER_SYNC_BATCH = toString cfg.hardcoverSync.batch;
        CALIBRE_HUB_HARDCOVER_SYNC_READ_AT = toString cfg.hardcoverSync.readAt;
        CALIBRE_HUB_HARDCOVER_SYNC_PRIVATE_TAGS = lib.concatStringsSep "," cfg.hardcoverSync.privateTags;
        CALIBRE_HUB_EMBED = lib.boolToString cfg.embed.enable;
        CALIBRE_HUB_EMBED_DELAY = toString cfg.embed.delay;
        CALIBRE_HUB_CONVERT = lib.boolToString cfg.convert.enable;
        CALIBRE_HUB_CONVERT_TARGET = cfg.convert.target;
        CALIBRE_HUB_CONVERT_IGNORE = lib.concatStringsSep "," cfg.convert.ignore;
        CALIBRE_HUB_DUPLICATES_THRESHOLD = toString cfg.duplicates.threshold;
        CALIBRE_HUB_EPUB_FIX_ON_IMPORT = lib.boolToString cfg.epubFix.onImport;
        CALIBRE_HUB_EPUB_FIX_KEEP_ORIGINAL = lib.boolToString cfg.epubFix.keepOriginal;
        CALIBRE_HUB_FRONTEND =lib.optionalString (cfg.frontend.package != null) "${cfg.frontend.package}";
        CALIBRE_HUB_LOGIN_USER = cfg.login.user;
        CALIBRE_HUB_LOGIN_PASSWORD_FILE = "%d/login-password";
        CALIBRE_HUB_SESSION_KEY_FILE = "%d/session-key";
        CALIBRE_HUB_SESSION_DAYS = toString cfg.sessionDays;
        CALIBRE_HUB_API_TOKEN_FILES = lib.concatStringsSep "," (
          lib.imap0 (i: _: "%d/${tokenCred i}") cfg.apiTokenFiles
        );
        CALIBRE_HUB_USERS = hubUsersEnv;
        # readers with a reader folder of their own may sync their lists
        CALIBRE_HUB_SYNC_USERS = lib.concatStringsSep "," (lib.optionals cfg.leseliste.enable syncUsers);
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
        ++ hubUsersCreds
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
