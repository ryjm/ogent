Initial pre-freeze baseline runs, preserved before final paired replay.
R018 included 36 selected tests: 34 unexpected, 2 skipped for absent rg.
The first recorder omitted lowercase skipped result lines and rejected R018;
the full ERT transcript retains the actual counts. Final records fix parsing
and use an actual portable rg binary so optional selected tests run.
