# vendor

## reactor_process 0.5.0

Unpacked from Hex (`mix hex.package fetch reactor_process 0.5.0 --unpack`). The only change is
`mix.exs`: `{:reactor, "== 1.0.6"}` -> `{:reactor, "~> 1.0"}`, because upstream's exact pin
conflicts with the current `reactor` 1.0.7 (pinned in `mix.lock`). Licences are retained in
`LICENSES/`. The copy is wired as a path dependency in `mix.exs`
(`{:reactor_process, path: "vendor/reactor_process", only: [:dev, :test]}`) — dev and test
only, never a runtime dep. Drop this
directory and use the Hex package once upstream relaxes the pin.
