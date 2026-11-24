# Contributors

- [Felix Sargent](https://github.com/fsargent) created and maintains TypeMouse.

## Develop TypeMouse

Follow the [source build instructions](README.md#build-and-install-from-source) to run TypeMouse locally.
Run `make test` before opening a pull request.

## Publish a release

Maintainers publish releases from `main`. Run the release workflow by hand to check signing and notarization before creating a tag.

```sh
gh workflow run release.yml --ref main
```

After the workflow succeeds, create and push a signed version tag. Replace `0.2.0` with the version you want to publish.

```sh
git tag -s v0.2.0 -m "TypeMouse 0.2.0"
git push origin v0.2.0
```

The tag starts the [release workflow](.github/workflows/release.yml). It tests, signs, and notarizes the universal app.
It then publishes the ZIP and its SHA-256 checksum and updates the [Homebrew tap](https://github.com/fsargent/homebrew-tap).

The GitHub Actions `release` environment uses these secrets.

- Signing uses `DEVELOPER_ID_P12` and `DEVELOPER_ID_P12_PASSWORD`.
- Notarization uses `APPLE_NOTARY_ID`, `APPLE_NOTARY_TEAM_ID`, and `APPLE_NOTARY_PASSWORD`.

The tap update uses the repository secret `HOMEBREW_TAP_DEPLOY_KEY`.
If the tap update fails after publication, rerun the failed job from GitHub Actions.
