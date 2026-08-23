# VR Viewer — GitHub macOS build

This project is configured with a GitHub Actions workflow at `.github/workflows/build-ios.yml`.

## What it does

- Runs on GitHub's hosted macOS runner.
- Uses the repository's `VR Viewer.xcodeproj` and shared `VR Viewer` scheme.
- Attempts a Release archive with Xcode.
- Packages the resulting `.app` as an **unsigned IPA** artifact.
- Uploads the Xcode build log if the build fails.

## Important

The project currently contains an Apple Development Team ID belonging to the original project configuration. Do **not** rely on that ID for signing your own device. For a device-installable IPA, the app must be signed with your own Apple Developer credentials and an appropriate provisioning profile.

The unsigned IPA is useful for verifying that the source compiles on the GitHub macOS runner, but it cannot normally be installed on an iPhone as-is.

## GitHub setup

1. Create a GitHub repository and upload the project contents.
2. Open **Actions** and select **Build VR Viewer iOS**.
3. Choose **Run workflow**.
4. After it finishes, open the workflow run and download the `VR-Viewer-unsigned-ipa` artifact.
5. If the build fails, download `xcodebuild-log` and inspect the first compiler error.

## Device installation

For a signed IPA, configure your own Apple Developer signing certificate and provisioning profile in GitHub Actions secrets, then change the workflow to archive/export with signing enabled. GitHub's documentation recommends keeping signing certificates and provisioning profiles in encrypted repository secrets.
