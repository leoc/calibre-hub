# Static web app; $out is the content of dist/ (index.html at the top).
# After changing dependencies: set hash = lib.fakeHash, build, take the new hash.
{
  lib,
  stdenv,
  nodejs,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "calibre-hub-frontend";
  version = (lib.importJSON ./package.json).version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./pnpm-lock.yaml
      ./index.html
      ./tsconfig.json
      ./vite.config.ts
      ./eslint.config.js
      ./playwright.config.ts
      ./src
      ./e2e
      ./public
      ./vendor
    ];
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-vACGacUnMNL7KFrQe3ZyfpeNjhBWPsHRryw9Vn3lumM=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm_11
    pnpmConfigHook
  ];

  buildPhase = ''
    runHook preBuild
    pnpm build
    runHook postBuild
  '';

  # typecheck runs in `pnpm build`; lint and unit tests here
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    pnpm lint
    pnpm test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';
})
