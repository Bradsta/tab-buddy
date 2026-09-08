# Guitar Pro fixtures

`practice.gp` is an original four-bar open-string/scale exercise created for Tab
Buddy, exported with alphaTab 1.8.4. It is covered by the repository's MIT license.
It exercises the modern zipped Guitar Pro format, offline rendering, playback,
and normalized bar-range looping in `GuitarProTests`.

`piano-practice.gp` is an original four-bar, two-staff piano exercise under the
repository MIT license. It verifies staff notation and instrument/credit metadata
without converting piano notes into guitar tablature.

Additional real-file checks used these free GProTab downloads on 2026-09-05:

- https://gprotab.net/en/tabs/the-beatles/let-it-be?download
  GP3; title `Let It Be`; one track; 18 bars.
- https://gprotab.net/en/tabs/jerryc/canon-rock?download
  GPX; title `Canon Rock`; seven tracks; 226 bars.

Downloaded song arrangements are local test inputs, not redistributed in the
repository or app. Run `node Tools/check-guitar-pro.cjs /path/to/file.gp3
/path/to/file.gpx` to validate additional files with the exact bundled runtime.
