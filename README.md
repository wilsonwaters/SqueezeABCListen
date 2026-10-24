# release-assets

This branch holds the plugin zips that `repo.xml` on `main` points LMS at, served by
raw.githubusercontent.com from this branch (`ABCListen-X.Y.Z.zip`). The Release workflow
(`.github/workflows/release.yml` on `main`) adds one zip per release: the same file that is
attached to the GitHub Release of that version, whose SHA1 is the `<sha>` in `repo.xml`.

- **Don't merge this branch** into `main` or anything else, and don't merge anything into it.
  It shares no history with `main`.
- **Never change or delete a zip here.** LMS installs from these URLs and checks each file's SHA1.
- Why not the GitHub Release download URL: LMS 9.1.1 can't read the redirect GitHub sends for
  it (a header line longer than 8,192 characters).

See `RELEASING.md` on `main`.
