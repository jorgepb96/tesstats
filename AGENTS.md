# Repository instructions for Codex

## TestFlight releases

When the user asks to publish, upload, release, or update Tesstats in TestFlight:

1. Follow [`docs/TESTFLIGHT_RELEASE.md`](docs/TESTFLIGHT_RELEASE.md) completely.
2. Treat the requested destination as **TestFlight internal testing only** unless the user explicitly changes that scope.
3. Never submit an App Store version for review, publish it publicly, or complete public-store compliance, pricing, or product-page forms as part of a TestFlight request.
4. Increment `CURRENT_PROJECT_VERSION` for every upload. Change `MARKETING_VERSION` only when the user intends a new user-facing version.
5. Generate the Xcode project from `project.yml`; never edit or commit the generated `.xcodeproj`.
6. Run the proportionate tests, archive with automatic signing, upload with the committed export-options template, and verify processing in App Store Connect.
7. Keep credentials, API keys, provisioning profiles, archives, exported IPAs, result bundles, logs, and screenshots out of Git.
8. After a successful upload, report the version/build, processing state, assigned internal group, tester availability, and any remaining action. Do not claim success until App Store Connect confirms the build.
