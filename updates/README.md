# Signed updates

Voidamp uses Sparkle 2.10.0. Source, binaries and the signed feed are all in `lumen-xx/voidamp`; the feed is the `appcast.xml` asset of the latest release. Builds up to 1.1.36 read the feed of `lumen-xx/voidamp-releases` (`updates/legacy-repository.txt`), and builds up to 1.1.14 reach it through that repository's old name, `voidmap-releases`, which GitHub redirects. Publishing therefore also creates a release there that carries only the new signed feed. Don't delete or rename `voidamp-releases`, and don't create a repository named `voidmap-releases`, or those copies stop getting updates.

The public key in `public-key.txt` is safe to commit. The private Ed25519 signing key stays in the local macOS login Keychain under account `app.voidamp.mac.updates`. Never export it into the repository or release assets. Back up the login Keychain securely: future releases must use this same key.

## Prepare and publish

```sh
bash scripts/prepare-release.sh 1.1.0 2
bash scripts/publish-release.sh 1.1.0
```

Increase both the marketing version and the numeric build for each release. Preparation builds a self-contained app, preserves Sparkle framework symlinks and nested signatures, creates a ZIP, generates the signed feed, and verifies both signatures. The current build script produces an Apple silicon app; Sparkle advertises the architecture requirement in the feed. Published versions cannot be overwritten by the preparation script.

Publishing is a separate explicit action. It uploads only the app archive and signed feed. Do not edit a generated feed after signing. Old feed entries are carried forward from the previous release and retain their version-specific asset URLs.

## Security and installation

Both `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are enabled. Automatic checks are enabled by default; automatic installation is not. The More menu offers “Check for Updates…”. Sparkle validates signed archives before extracting them and presents its standard update interface.

Sparkle signatures authenticate updates but do not provide Apple Developer ID signing or notarization. The first installation of this self-signed app (“Voidamp Local Signing”) may still require macOS approval. Existing installations without Sparkle need a one-time installation of this updater-enabled build. Developer ID signing and notarization remain recommended for wider distribution.

## Verification

```sh
python3 scripts/verify-release.py dist/releases/1.1.0/appcast.xml dist/releases/1.1.0/Voidamp-1.1.0.zip 2
```

This checks archive metadata, inclusion of Sparkle, the archive signature, and the signed feed. It does not simulate replacing a running installation; an older updater-enabled build is needed for that end-to-end test.

Reference: https://sparkle-project.org/documentation/
