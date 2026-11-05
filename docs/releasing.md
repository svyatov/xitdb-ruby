# Releasing

The gem is named `xitdb`. Releases use the `vVERSION` tag and RubyGems trusted publishing from GitHub Actions.
The release workflow requires every CI job to pass before publishing: Ruby quality checks, four reference implementations, and Linux memory tests.

## Publisher setup

Register a [pending trusted publisher](https://rubygems.org/profile/oidc/pending_trusted_publishers/new) for the first release:

| Field | Value |
| --- | --- |
| Gem name | `xitdb` |
| Repository owner | `svyatov` |
| Repository name | `xitdb-ruby` |
| Workflow filename | `release.yml` |
| Environment | `release` |

Leave the optional workflow repository fields empty. Create the `release` environment in the GitHub repository settings.
After the first publication, RubyGems converts the pending publisher into a publisher for the gem.
See [RubyGems trusted publishing](https://guides.rubygems.org/trusted-publishing/) for authentication details.

## Release procedure

1. Set `XitDB::VERSION` in `lib/xitdb/version.rb` to the release version.
2. Update README examples and move changelog entries into a dated version section.
3. Run `bundle exec ruby script/ci.rb` to verify quality and the installed package.
4. Commit the release changes and push them to GitHub.
5. Create the matching tag, for example `git tag -a v0.1.0 -m "Release 0.1.0"`.
6. Push the tag with `git push origin v0.1.0`.
7. Check the Release workflow and confirm the version and checksum on RubyGems before announcing publication.

The workflow rejects tags that differ from the packaged version.
It builds the gem before requesting credentials, then authenticates through GitHub OIDC with permission to publish `xitdb`.
No persistent RubyGems API key is required.

If publisher registration fails, correct the RubyGems settings and rerun the failed job on the same tag.
For a published version, make corrections in a subsequent release; RubyGems does not permit replacement of a version.
