# wkhtmltopdf parity check

**Will your PDFs change if you replace wkhtmltopdf?** This GitHub Action answers with evidence, on every pull request. It makes your own HTML templates into PDFs with wkhtmltopdf 0.12.6 and with marqius-wkhtmltopdf, the maintained drop-in replacement, compares every page, and fails the build on the differences you choose. The invoices, statements and reports your customers receive are checked before the switch, not after.

```yaml
name: PDF parity
on: [push, pull_request]
permissions:
  contents: read
  pull-requests: write
jobs:
  parity:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: marqiushq/wkhtmltopdf-parity-check@v1
        with:
          pages: templates/*.html
          options: --page-size A4 --margin-top 12mm --enable-local-file-access
```

Name your templates in `pages` and the options your application passes in `options`. That is all it needs. `pull-requests: write` lets it post the result on the pull request.

## What you get

- **A verdict for every page,** such as the same, appearance only or content differs, and a decision for the whole set: GO, REVIEW or NO-GO.
- **The result on the pull request:** one comment with the decision and the pages that differ, the templates the pull request changes marked, updated by every later run rather than posted again.
- **A note where it matters:** each page that differs gets an annotation on its file with its most serious difference, such as `1,234.50 is now 1,234.60 (+0.10)`, in the run's summary and beside the file in a pull request that changes it.
- **The evidence:** the artifact `wkhtmltopdf-parity` holds both PDFs of every page, marked-up copies of those that differ, with a frame and a note at each difference, pictures of those pages side by side, and the whole comparison as CSV and JSON.
- **The time each program took** to convert your pages, side by side on the runner.

## A fair comparison

Both programs run side by side in one container: wkhtmltopdf 0.12.6 (with patched Qt) on Alpine Linux, the image the [wkhtmltopdf parity suite](https://github.com/marqiushq/wkhtmltopdf-parity) measures in, pinned by its digest. They see the same system and the same fonts, with no network, and marqius-wkhtmltopdf is started under the name wkhtmltopdf, as your libraries start it. A difference in the report is a difference between the two programs, not between two machines.

## Choose what fails the build

`marqius-wkhtmltopdf compare` gives each difference a level:

- **blocking:** the content differs: words, numbers, dates, pictures that are missing, new or changed;
- **review:** worth a look: a page that begins at another word, another number of pages, a number written another way, another kind of PDF;
- **cosmetic:** words a point or two from where they stood, another typeface or size of type, a slightly different shade, the file's description.

`fail-on` sets the level that fails the check: `blocking` unless you choose otherwise. `compare-options` changes the levels, or leaves differences out:

```yaml
- uses: marqiushq/wkhtmltopdf-parity-check@v1
  with:
    pages: templates/*.html
    options: --page-size A4 --margin-top 12mm --enable-local-file-access
    fail-on: cosmetic
    compare-options: --ignore-kind metadata --move 2
```

Here every difference fails the check, except two: `--ignore-kind metadata` leaves out the file's description (marqius-wkhtmltopdf records the page's language, where wkhtmltopdf leaves it blank), and `--move 2` lets words stand up to 2 points from where they stood. `marqius-wkhtmltopdf compare --help` lists every option, and `marqius-wkhtmltopdf compare kinds` every kind of difference with its level.

## Compare with the PDFs your servers make

Your servers may run another wkhtmltopdf than 0.12.6, or have other fonts. Commit PDFs your servers made, named like the pages (`invoice.html` gives `invoice.pdf`), and give their folder as `baseline`:

```yaml
- uses: marqiushq/wkhtmltopdf-parity-check@v1
  with:
    pages: templates/*.html
    options: --page-size A4 --margin-top 12mm --enable-local-file-access
    baseline: templates/made-by-wkhtmltopdf
```

marqius-wkhtmltopdf then runs on the runner itself, with the runner's fonts and those in `fonts`. No Docker is needed, so this works on macOS runners too.

## Report without failing the build

For a first look, let the job carry on and show the decision:

```yaml
- id: parity
  uses: marqiushq/wkhtmltopdf-parity-check@v1
  continue-on-error: true
  with:
    pages: templates/*.html
- run: echo "$DECISION"
  env:
    DECISION: ${{ steps.parity.outputs.decision }}
```

## Inputs

| Input | Default | What it is |
|---|---|---|
| `pages` | (required) | The HTML pages to convert, inside the repository: paths or patterns, one to a line. Files the options name, such as a footer in `--footer-html`, are not converted on their own |
| `options` | none | The wkhtmltopdf options your application passes, as on a command line; quotes work as in a shell |
| `fail-on` | `blocking` | The level of difference that fails the check: `blocking`, `review` or `cosmetic` |
| `compare-options` | none | Options for `marqius-wkhtmltopdf compare`, to change levels or leave differences out |
| `baseline` | none | A folder of PDFs your servers made, named like the pages. Without it, wkhtmltopdf 0.12.6 makes them in Docker |
| `fonts` | none | A folder of fonts your servers have (`.ttf`, `.otf`, `.ttc`), for both programs |
| `network` | `false` | `true` lets both programs load files from the internet, such as style sheets from a CDN |
| `version` | `latest` | The release of marqius-wkhtmltopdf to test, such as `0.12.9` |
| `report` | `wkhtmltopdf-parity` | The folder for the report, inside the repository's folder; the artifact takes its name. Give each job its own when several jobs run the check |
| `comment` | `true` | Posts the result on the pull request, as one comment for each report that every later run updates. `false` leaves the pull request alone |
| `token` | the workflow's token | The token that posts the comment |

## Outputs

| Output | What it is |
|---|---|
| `verdict` | `pass`, or `fail` when a difference at the `fail-on` level or above was found |
| `decision` | The decision for all the pages, such as `GO: nothing blocking and nothing to look at` |
| `report` | The folder the report is in |

## What it needs

- **Without a baseline,** a Linux runner with Docker: GitHub's Ubuntu runners, x86-64 or ARM64. The wkhtmltopdf image is a download of about 135 MB, once a job.
- **marqius-wkhtmltopdf** comes from [setup-marqius-wkhtmltopdf](https://github.com/marqiushq/setup-marqius-wkhtmltopdf), checked against its published checksum and kept in the Actions cache. It runs on Linux and macOS runners; Windows runners are not supported yet.
- **For the comment,** `permissions: pull-requests: write` in the workflow. A pull request from a fork gets a token that can only read, so there the check still runs and reports, without the comment.
- **Your pages and what they load** stay on the runner. The programs convert with no network unless you set `network: true`.

## Run it on your own machine

The [wkhtmltopdf parity suite](https://github.com/marqiushq/wkhtmltopdf-parity) does the same on any computer with Docker: put your templates in `mine/` and run `./run.sh mine`. It also publishes the comparison of its own documents for every release of marqius-wkhtmltopdf, misses included.

## Licence

This action is open source under the MIT licence. The sample templates come from the parity suite, under CC0. marqius-wkhtmltopdf is commercial software from Simple AI LLC, with a 30-day free trial counted from its first run; [plans and licences](https://marqius.com/wkhtmltopdf/). marqius-wkhtmltopdf is not affiliated with the wkhtmltopdf project.

Questions and help: hello@marqius.com, or [an issue](https://github.com/marqiushq/wkhtmltopdf-parity-check/issues).
